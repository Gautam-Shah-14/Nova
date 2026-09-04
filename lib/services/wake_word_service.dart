import 'dart:async';

import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../config/nova_config.dart';
import '../controllers/status_controller.dart';
import '../models/nova_status.dart';
import '../models/wake_event.dart';
import '../utils/logger.dart';
import 'native_bridge.dart';
import 'vosk_service.dart';

/// Wake phrase + command capture, fully offline via [VoskService]. One
/// continuous Vosk recogniser runs while the foreground service keeps the
/// process (and its mic-typed FGS) alive.
///
/// Flow: final utterance -> contains a wake alias? -> chime, then either the
/// words after the alias are the command, or the next utterance is -> emit a
/// [WakeEvent]. The mic is paused while Nova is `working` so it doesn't
/// transcribe its own TTS.
class WakeWordService {
  WakeWordService({
    required this.status,
    required this.vosk,
    NativeBridge? bridge,
  }) : _bridge = bridge ?? NativeBridge.instance;

  final StatusController status;
  final VoskService vosk;
  final NativeBridge _bridge;

  final _hits = StreamController<WakeEvent>.broadcast();
  Stream<WakeEvent> get onWake => _hits.stream;

  Worker? _statusWorker;
  StreamSubscription<String>? _finalSub;
  bool _running = false;
  bool _expectingCommand = false;
  Timer? _commandTimeout;

  bool get speechAvailable => vosk.ready;
  bool get isRunning => _running;

  Future<void> start() async {
    if (_running) return;
    try {
      await _bridge.startListening(); // FGS: notification + wake lock
    } catch (e) {
      log.w('startListening (FGS) failed: $e');
    }

    if (!vosk.ready) {
      try {
        await vosk.init();
      } catch (e, s) {
        log.e('vosk.init threw', e, s);
      }
    }
    if (!vosk.ready) {
      log.e('Vosk unavailable — wake word disabled');
      return;
    }

    try {
      await vosk.start();
    } catch (e, s) {
      log.e('vosk.start threw — wake word disabled', e, s);
      return;
    }
    _running = true;

    _finalSub = vosk.finals.listen(_onFinal);
    _statusWorker = ever<NovaStatus>(status.status, (s) {
      if (s == NovaStatus.working) {
        vosk.setPaused(true);
      } else if (s == NovaStatus.available && _running) {
        vosk.setPaused(false);
      }
    });

    log.i('WakeWordService armed — say "${NovaConfig.wakePhrase}"');
  }

  Future<void> stop() async {
    _running = false;
    _commandTimeout?.cancel();
    _statusWorker?.dispose();
    _statusWorker = null;
    await _finalSub?.cancel();
    _finalSub = null;
    await vosk.stop();
    await _bridge.stopListening();
  }

  /// Debug hook — next spoken utterance is taken as a command, no wake needed.
  Future<void> simulate() async {
    HapticFeedback.mediumImpact();
    _expectingCommand = true;
    _armCommandTimeout();
  }

  void _onFinal(String text) {
    if (text.isEmpty) return;
    log.d('heard: "$text"');

    if (_expectingCommand) {
      _expectingCommand = false;
      _commandTimeout?.cancel();
      _emit(text);
      return;
    }

    for (final alias in NovaConfig.wakeAliases) {
      final idx = text.indexOf(alias);
      if (idx < 0) continue;
      _chime();
      final tail = text
          .substring(idx + alias.length)
          .replaceFirst(RegExp(r'^[,.!?\s]+'), '')
          .trim();
      if (tail.isNotEmpty) {
        _emit(tail);
      } else {
        _expectingCommand = true;
        _armCommandTimeout();
      }
      return;
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

  void _chime() {
    HapticFeedback.mediumImpact();
    SystemSound.play(SystemSoundType.click);
  }

  Future<void> dispose() async {
    await stop();
    await _hits.close();
  }
}
