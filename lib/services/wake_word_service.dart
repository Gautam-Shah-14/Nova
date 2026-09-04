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
import 'sherpa_wake_engine.dart';
import 'tts_service.dart';

/// Wake phrase + command capture. Two backends for the "wait for Tony" part:
///
/// - **[SherpaWakeEngine]** — free, offline, bundled model. Decodes raw mic
///   samples directly and never opens an Android recognition session, so it
///   never grabs audio focus and doesn't duck/pause other apps' audio while
///   it's just waiting. Used automatically whenever it initialises OK.
/// - **`speech_to_text`** (Android's `SpeechRecognizer`) — the fallback,
///   always available, no setup, but ducks other audio on every session.
///
/// Either way, once "Tony" is heard, `speech_to_text` captures the actual
/// command (a short, expected interruption — same as any voice assistant
/// actively listening for what you want). Recognition is suspended while Nova
/// is `working` (or speaking) so it doesn't transcribe its own TTS.
///
/// In the `speech_to_text`-only fallback, sessions are short-lived and end on
/// their own — on a quiet mic they can end almost immediately, and restarting
/// one instantly on every such end is what produces rapid on/off "listening"
/// chimes. Two things tame that: [_minListenGap] is a hard floor under how
/// often a session can (re)start at all, and [_backoffSteps] grows the
/// relisten delay the longer nothing's been heard, resetting the moment real
/// speech comes back. A [_watchdog] timer separately force-restarts listening
/// if it ever finds the recognizer idle with nothing scheduled while Nova
/// should be armed.
class WakeWordService {
  WakeWordService({
    required this.status,
    required this.tts,
    NativeBridge? bridge,
    SherpaWakeEngine? sherpa,
  })  : _bridge = bridge ?? NativeBridge.instance,
        _sherpa = sherpa ?? SherpaWakeEngine();

  final StatusController status;
  final TtsService tts;
  final NativeBridge _bridge;
  final SpeechToText _speech = SpeechToText();
  final SherpaWakeEngine _sherpa;

  final _hits = StreamController<WakeEvent>.broadcast();
  Stream<WakeEvent> get onWake => _hits.stream;

  Worker? _statusWorker;
  Timer? _watchdog;
  bool _available = false;
  bool _running = false;
  bool _paused = false;
  bool _expectingCommand = false;
  bool _acknowledging = false;

  /// True once [start] confirms the offline engine initialised — decides
  /// which backend owns "waiting for Tony" for this session.
  bool _offlineMode = false;
  /// True only when the offline engine is both selected AND actually
  /// receiving mic audio — not just "the model loaded". See
  /// [SherpaWakeEngine.capturing].
  bool get usingOfflineWakeWord => _offlineMode && _sherpa.capturing;

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

    // speech_to_text is always initialised — the offline engine only
    // replaces who waits for "Tony"; speech_to_text still captures the
    // command either way.
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

    _offlineMode = await _sherpa.init(_onOfflineWake);

    if (!_available && !_offlineMode) {
      log.e('no wake engine available (offline KWS failed, SpeechRecognizer unavailable)');
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

    if (_offlineMode) {
      await _sherpa.start();
      log.i('WakeWordService armed via offline KWS — say "${NovaConfig.wakePhrase}"');
    } else {
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
      log.i('WakeWordService armed via SpeechRecognizer — say "${NovaConfig.wakePhrase}"');
    }
  }

  Future<void> stop() async {
    _running = false;
    _relisten?.cancel();
    _commandTimeout?.cancel();
    _watchdog?.cancel();
    _watchdog = null;
    _statusWorker?.dispose();
    _statusWorker = null;
    if (_offlineMode) {
      await _sherpa.stop();
    }
    try {
      await _speech.stop();
    } catch (_) {}
    try {
      await _bridge.stopListening();
    } catch (_) {}
  }

  void _onOfflineWake() => unawaited(_onWakeDetected(''));

  /// Debug hook — behaves as if the wake phrase was heard with no trailing
  /// command, so the next spoken phrase is taken as the command.
  Future<void> simulate() async {
    HapticFeedback.mediumImpact();
    if (_offlineMode) await _sherpa.stop();
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

  /// Wake word confirmed (either engine): acknowledge out loud (mic paused
  /// while it speaks so it doesn't hear itself), then capture the command via
  /// speech_to_text. In offline-KWS mode, [tail] is always empty — the
  /// spotter only signals "woken", it doesn't transcribe.
  Future<void> _onWakeDetected(String tail) async {
    HapticFeedback.mediumImpact();
    _acknowledging = true;
    _relisten?.cancel();
    if (_offlineMode) {
      await _sherpa.stop(); // release the mic before speech_to_text needs it
    } else {
      try {
        _speech.cancel();
      } catch (_) {}
    }

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
        try {
          _speech.cancel();
        } catch (_) {}
        if (_offlineMode) unawaited(_sherpa.start());
      }
    });
  }

  void _suspend() {
    if (_paused) return;
    _paused = true;
    _relisten?.cancel();
    if (_offlineMode) {
      unawaited(_sherpa.stop());
    } else {
      _speech.cancel();
    }
  }

  void _resume() {
    if (!_paused) return;
    _paused = false;
    if (_offlineMode) {
      unawaited(_sherpa.start());
    } else {
      _scheduleRelisten(const Duration(milliseconds: 300));
    }
  }

  Future<void> dispose() async {
    await stop();
    await _sherpa.dispose();
    await _hits.close();
  }
}
