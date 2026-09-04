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
/// `SpeechRecognizer` sessions are short-lived and end on their own, and on a
/// quiet mic they can end almost immediately — restarting one instantly on
/// every such end is what produces the rapid on/off "listening" chime you'd
/// otherwise hear. Two things tame that: [_minListenGap] is a hard floor
/// under how often a session can (re)start at all, and [_backoffSteps] grows
/// the relisten delay the longer nothing's been heard, resetting the moment
/// real speech comes back. A [_watchdog] timer separately force-restarts
/// listening if it ever finds the recognizer idle with nothing scheduled
/// while Nova should be armed, so a missed relisten can't leave Nova silently
/// deaf until the app is manually restarted.
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

  /// Hard floor between session starts — the actual fix for the audible
  /// on/off churn: whatever asked for a relisten, [_listen] itself refuses to
  /// restart faster than this, no matter how many callers ask.
  static const _minListenGap = Duration(milliseconds: 1200);
  DateTime? _lastListenStart;

  /// Grows the relisten delay while nothing is being heard (silence, a room
  /// with no one talking) instead of retrying at a fixed fast cadence — the
  /// backoff steps, in order. Resets the moment real speech comes back.
  static const _backoffSteps = <Duration>[
    Duration(milliseconds: 500),
    Duration(milliseconds: 1000),
    Duration(milliseconds: 2000),
    Duration(seconds: 3),
  ];
  int _quietStreak = 0;
  Duration _backoffDelay() => _backoffSteps[_quietStreak.clamp(0, _backoffSteps.length - 1)];

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
    _quietStreak = 0;
    _lastListenStart = null;

    _statusWorker = ever<NovaStatus>(status.status, (s) {
      if (s == NovaStatus.working) {
        _suspend();
      } else if (s == NovaStatus.available && _running) {
        _resume();
      }
    });

    _watchdog = Timer.periodic(const Duration(seconds: 5), (_) {
      final relistenPending = _relisten?.isActive ?? false;
      if (_running &&
          !_paused &&
          !_acknowledging &&
          !_speech.isListening &&
          !relistenPending) {
        log.w('watchdog: recognizer was idle with nothing scheduled — restarting');
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

    // Hard floor: never restart a session faster than _minListenGap after the
    // last one started, regardless of what asked for this relisten. This is
    // what actually stops the rapid on/off churn — without it, a chain of
    // quick errors/empty results can retrigger listen() many times a second.
    final last = _lastListenStart;
    if (last != null) {
      final elapsed = DateTime.now().difference(last);
      if (elapsed < _minListenGap) {
        _scheduleRelisten(_minListenGap - elapsed);
        return;
      }
    }

    _lastListenStart = DateTime.now();
    _speech
        .listen(
          onResult: _onResult,
          listenOptions: SpeechListenOptions(
            partialResults: false,
            cancelOnError: true,
            listenMode: ListenMode.dictation,
            listenFor: const Duration(seconds: 12),
            pauseFor: const Duration(seconds: 3),
            localeId: 'en_US',
          ),
        )
        .catchError((Object e) {
      log.w('listen() threw: $e');
      _noteQuiet();
      _scheduleRelisten();
    });
  }

  /// Pass an explicit [delay] to override the backoff (e.g. the short,
  /// deliberate relisten right after the wake acknowledgement). Otherwise the
  /// backoff step for however long it's been quiet is used — [_listen] still
  /// enforces [_minListenGap] underneath regardless of what's asked for here.
  void _scheduleRelisten([Duration? delay]) {
    _relisten?.cancel();
    _relisten = Timer(delay ?? _backoffDelay(), _listen);
  }

  void _noteQuiet() => _quietStreak = (_quietStreak + 1).clamp(0, _backoffSteps.length - 1);
  void _noteHeardSpeech() => _quietStreak = 0;

  void _onStatus(String s) {
    if ((s == 'done' || s == 'notListening') &&
        _running &&
        !_paused &&
        !_acknowledging) {
      _scheduleRelisten();
    }
  }

  void _onError(SpeechRecognitionError e) {
    // no_match / speech_timeout are normal in a wake loop — just go again,
    // progressively slower the longer it's been since anyone said anything.
    if (_running && !_paused && !_acknowledging) {
      _noteQuiet();
      _scheduleRelisten();
    }
  }

  void _onResult(SpeechRecognitionResult r) {
    if (!r.finalResult) return;
    final text = r.recognizedWords.trim();
    if (text.isEmpty) {
      _noteQuiet();
      _scheduleRelisten();
      return;
    }
    // Real speech came back — drop the backoff and stay responsive.
    _noteHeardSpeech();
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
