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
import 'tts_service.dart';

/// Wake phrase + command capture via Android's `SpeechRecognizer`
/// (`speech_to_text`). Uses on-device recognition automatically on phones with
/// the offline language pack installed; falls back to Google's recognizer
/// otherwise. The native foreground service just keeps the process (and its
/// mic-typed FGS) alive; this class runs the listen loop.
///
/// Flow: final result -> contains a wake alias? -> speak the acknowledgement,
/// then either the words after the alias are the command, or the next
/// utterance is -> emit a [WakeEvent]. Recognition is suspended while Nova is
/// `working` (or speaking) so it doesn't transcribe its own TTS.
///
/// `SpeechRecognizer` sessions are short-lived and end on their own — a
/// [_watchdog] timer force-restarts listening if it ever finds the recognizer
/// idle while Nova should be armed, so a missed relisten (a dropped
/// callback, a status transition that didn't fire [_resume]) can't leave
/// Nova silently deaf until the app is manually restarted.
class WakeWordService {
  WakeWordService({required this.status, required this.tts, NativeBridge? bridge})
      : _bridge = bridge ?? NativeBridge.instance;

  final StatusController status;
  final TtsService tts;
  final NativeBridge _bridge;
  final SpeechToText _speech = SpeechToText();

  final _hits = StreamController<WakeEvent>.broadcast();
  Stream<WakeEvent> get onWake => _hits.stream;

  Worker? _statusWorker;
  Timer? _watchdog;
  bool _available = false;
  bool _running = false;
  bool _paused = false;
  bool _expectingCommand = false;
  bool _acknowledging = false;
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

    _watchdog = Timer.periodic(const Duration(seconds: 3), (_) {
      if (_running && !_paused && !_acknowledging && !_speech.isListening) {
        log.w('watchdog: recognizer was idle — restarting');
        _listen();
      }
    });

    _listen();
    log.i('WakeWordService armed — say "${NovaConfig.wakePhrase}"');
  }

  Future<void> stop() async {
    _running = false;
    _relisten?.cancel();
    _commandTimeout?.cancel();
    _watchdog?.cancel();
    _watchdog = null;
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
    if (!_running || _paused || _acknowledging) return;
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
        .catchError((Object e) {
      log.w('listen() threw: $e');
      _scheduleRelisten(const Duration(milliseconds: 800));
    });
  }

  void _scheduleRelisten([Duration delay = const Duration(milliseconds: 400)]) {
    _relisten?.cancel();
    _relisten = Timer(delay, _listen);
  }

  void _onStatus(String s) {
    if ((s == 'done' || s == 'notListening') &&
        _running &&
        !_paused &&
        !_acknowledging) {
      _scheduleRelisten();
    }
  }

  void _onError(SpeechRecognitionError e) {
    // no_match / speech_timeout are normal in a wake loop — just go again.
    if (_running && !_paused && !_acknowledging) {
      _scheduleRelisten(const Duration(milliseconds: 600));
    }
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
      final tail = text
          .substring(idx + alias.length)
          .replaceFirst(RegExp(r'^[,.!?\s]+'), '')
          .trim();
      unawaited(_onWakeDetected(tail));
      return;
    }
    // heard speech, no wake word — keep listening
    _scheduleRelisten();
  }

  /// Wake word confirmed: acknowledge out loud (mic paused while it speaks so
  /// it doesn't hear itself), then capture the command.
  Future<void> _onWakeDetected(String tail) async {
    HapticFeedback.mediumImpact();
    _acknowledging = true;
    _relisten?.cancel();
    try {
      _speech.cancel();
    } catch (_) {}

    try {
      await tts.speak(NovaConfig.wakeAcknowledgement);
    } catch (e) {
      log.w('wake acknowledgement failed: $e');
    }
    _acknowledging = false;

    if (tail.isNotEmpty) {
      _emit(tail);
    } else {
      _expectingCommand = true;
      _armCommandTimeout();
      _scheduleRelisten(const Duration(milliseconds: 150));
    }
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
