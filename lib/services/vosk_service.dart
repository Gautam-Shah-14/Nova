import 'dart:async';
import 'dart:convert';

import 'package:vosk_flutter_2/vosk_flutter_2.dart';

import '../utils/logger.dart';

/// Owns the Vosk offline recogniser + mic stream. Fully on-device — the ~40MB
/// English model is bundled in the APK and unpacked to app storage on first
/// run. One continuous recogniser feeds both the wake-word check and command
/// capture (see [WakeWordService]).
class VoskService {
  static const String _modelAsset =
      'assets/models/vosk-model-small-en-us-0.15.zip';
  static const int _sampleRate = 16000;

  final VoskFlutterPlugin _vosk = VoskFlutterPlugin.instance();

  Model? _model;
  Recognizer? _recognizer;
  SpeechService? _speech;
  bool _ready = false;
  bool _started = false;

  final _partials = StreamController<String>.broadcast();
  final _finals = StreamController<String>.broadcast();
  StreamSubscription<String>? _pSub;
  StreamSubscription<String>? _fSub;

  bool get ready => _ready;
  bool get running => _started;

  /// Lowercased partial hypotheses — used for a fast wake-word trigger.
  Stream<String> get partials => _partials.stream;

  /// Lowercased final utterances.
  Stream<String> get finals => _finals.stream;

  Future<void> init() async {
    if (_ready) return;
    try {
      final modelPath = await ModelLoader().loadFromAssets(_modelAsset);
      _model = await _vosk.createModel(modelPath);
      _recognizer = await _vosk.createRecognizer(
        model: _model!,
        sampleRate: _sampleRate,
      );
      _speech = await _vosk.initSpeechService(_recognizer!);
      _ready = true;
      log.i('VoskService ready ($modelPath)');
    } catch (e, s) {
      log.e('VoskService.init failed', e, s);
      _ready = false;
    }
  }

  Future<void> start() async {
    if (!_ready || _started) return;
    _pSub = _speech!.onPartial().listen((raw) {
      final t = _extract(raw, 'partial');
      if (t.isNotEmpty) _partials.add(t);
    });
    _fSub = _speech!.onResult().listen((raw) {
      final t = _extract(raw, 'text');
      if (t.isNotEmpty) _finals.add(t);
    });
    await _speech!.start();
    _started = true;
    log.i('VoskService listening');
  }

  Future<void> stop() async {
    if (!_started) return;
    _started = false;
    await _pSub?.cancel();
    await _fSub?.cancel();
    _pSub = null;
    _fSub = null;
    try {
      await _speech?.stop();
    } catch (_) {}
  }

  /// Pause/resume the mic without tearing down the recogniser — used while Nova
  /// is speaking so it doesn't transcribe its own TTS.
  Future<void> setPaused(bool paused) async {
    if (!_started) return;
    try {
      await _speech?.setPause(paused: paused);
    } catch (e) {
      log.w('vosk setPause($paused) failed: $e');
    }
  }

  String _extract(String rawJson, String key) {
    try {
      final map = jsonDecode(rawJson);
      if (map is Map && map[key] is String) {
        return (map[key] as String).toLowerCase().trim();
      }
    } catch (_) {}
    return '';
  }

  Future<void> dispose() async {
    await stop();
    try {
      await _speech?.dispose();
    } catch (_) {}
    await _partials.close();
    await _finals.close();
    _ready = false;
  }
}
