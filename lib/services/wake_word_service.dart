import 'dart:async';

import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

import '../config/nova_config.dart';
import '../controllers/status_controller.dart';
import '../models/nova_status.dart';
import '../models/wake_event.dart';
import '../utils/logger.dart';
import 'native_bridge.dart';

/// Wake phrase + command capture via Android's `SpeechRecognizer`
/// (`speech_to_text`). Uses on-device recognition automatically on phones with
/// the offline language pack installed; falls back to Google's recognizer
/// otherwise. The native foreground service just keeps the process (and its
/// mic-typed FGS) alive; this class runs the listen loop.
///
/// Flow: final result -> contains a wake alias? -> chime, then either the
/// words after the alias are the command, or the next utterance is -> emit a
/// [WakeEvent]. Recognition is suspended while Nova is `working` so it doesn't
/// transcribe its own TTS.
class WakeWordService {
  WakeWordService({required this.status, NativeBridge? bridge})
      : _bridge = bridge ?? NativeBridge.instance;

  final StatusController status;
  final NativeBridge _bridge;
  final SpeechToText _speech = SpeechToText();

  final _hits = StreamController<WakeEvent>.broadcast();
  Stream<WakeEvent> get onWake => _hits.stream;

  Worker? _statusWorker;
  bool _available = false;
  bool _running = false;
  bool _paused = false;
  bool _expectingCommand = false;
  Timer? _relisten;
  Timer? _commandTimeout;

  bool get speechAvailable => _available;
  bool get isRunning => _running;

  Future<void> start() async {
    if (_running) return;
    try {
      await _bridge.startListening(); // FGS: notification + wake lock
    } catch (e) {
      log.w('startListening (FGS) failed: $e');
    }

    try {
      _available = await _speech.initialize(
        onError: _onError,
        onStatus: _onStatus,
        debugLogging: false,
      );
    } catch (e, s) {
      log.e('speech.initialize threw', e, s);
      _available = false;
    }
    if (!_available) {
      log.e('speech recognition unavailable on this device');
      return;
    }
    _running = true;
    _paused = false;

    _statusWorker = ever<NovaStatus>(status.status, (s) {
      if (s == NovaStatus.working) {
        _suspend();
      } else if (s == NovaStatus.available && _running) {
        _resume();
      }
    });

    _listen();
    log.i('WakeWordService armed — say "${NovaConfig.wakePhrase}"');
  }

  Future<void> stop() async {
    _running = false;
    _relisten?.cancel();
    _commandTimeout?.cancel();
    _statusWorker?.dispose();
    _statusWorker = null;
    try {
      await _speech.stop();
    } catch (_) {}
    try {
      await _bridge.stopListening();
    } catch (_) {}
  }

  /// Debug hook — behaves as if the wake phrase was heard with no trailing
  /// command, so the next spoken phrase is taken as the command.
  Future<void> simulate() async {
    HapticFeedback.mediumImpact();
    _expectingCommand = true;
    _armCommandTimeout();
    _listen();
  }

  // ── listen loop ────────────────────────────────────────────────────────
  void _listen() {
    if (!_running || _paused) return;
    if (_speech.isListening) return;
    _speech
        .listen(
          onResult: _onResult,
          listenOptions: SpeechListenOptions(
            partialResults: false,
            cancelOnError: true,
            listenMode: ListenMode.dictation,
            listenFor: const Duration(seconds: 10),
            pauseFor: const Duration(seconds: 3),
            localeId: 'en_US',
          ),
        )
        .catchError((Object e) => log.w('listen() threw: $e'));
  }

  void _scheduleRelisten([Duration delay = const Duration(milliseconds: 400)]) {
    _relisten?.cancel();
    _relisten = Timer(delay, _listen);
  }

  void _onStatus(String s) {
    if ((s == 'done' || s == 'notListening') && _running && !_paused) {
      _scheduleRelisten();
    }
  }

  void _onError(SpeechRecognitionError e) {
    // no_match / speech_timeout are normal in a wake loop — just go again.
    if (_running && !_paused) _scheduleRelisten(const Duration(milliseconds: 600));
  }

  void _onResult(SpeechRecognitionResult r) {
    if (!r.finalResult) return;
    final text = r.recognizedWords.trim();
    if (text.isEmpty) {
      _scheduleRelisten();
      return;
    }
    final lower = text.toLowerCase();
    log.d('heard: "$text"');

    if (_expectingCommand) {
      _expectingCommand = false;
      _commandTimeout?.cancel();
      _emit(text);
      return;
    }

    for (final alias in NovaConfig.wakeAliases) {
      final idx = lower.indexOf(alias);
      if (idx < 0) continue;
      _chime();
      final tail = text.substring(idx + alias.length).trim();
      final cleaned = tail.replaceFirst(RegExp(r'^[,.!?\s]+'), '');
      if (cleaned.isNotEmpty) {
        _emit(cleaned);
      } else {
        _expectingCommand = true;
        _armCommandTimeout();
        _scheduleRelisten(const Duration(milliseconds: 150));
      }
      return;
    }
    // heard speech, no wake word — keep listening
    _scheduleRelisten();
  }

  void _emit(String command) {
    log.i('wake -> command: "$command"');
    _hits.add(WakeEvent(at: DateTime.now(), command: command));
  }

  void _armCommandTimeout() {
    _commandTimeout?.cancel();
    _commandTimeout = Timer(const Duration(seconds: 8), () {
      if (_expectingCommand) {
        _expectingCommand = false;
        log.i('no command after wake — back to idle');
      }
    });
  }

  void _chime() {
    HapticFeedback.mediumImpact();
    SystemSound.play(SystemSoundType.click);
  }

  void _suspend() {
    if (_paused) return;
    _paused = true;
    _relisten?.cancel();
    _speech.cancel();
  }

  void _resume() {
    if (!_paused) return;
    _paused = false;
    _scheduleRelisten(const Duration(milliseconds: 300));
  }

  Future<void> dispose() async {
    await stop();
    await _hits.close();
  }
}
