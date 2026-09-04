import 'dart:io' show Platform;

import 'package:flutter_tts/flutter_tts.dart';

import '../utils/logger.dart';

/// Text-to-speech via Android's built-in TextToSpeech engine (`flutter_tts`).
/// Real audio out, no native build. The Piper "your voice" model from the
/// design doc is a later swap behind this same interface.
class TtsService {
  final FlutterTts _tts = FlutterTts();
  bool _ready = false;
  String _lastError = '';

  bool get ready => _ready;
  String get lastError => _lastError;

  Future<void> init() async {
    try {
      _tts.setStartHandler(() => log.d('tts: start'));
      _tts.setCompletionHandler(() => log.d('tts: done'));
      _tts.setErrorHandler((msg) {
        _lastError = msg.toString();
        log.e('tts error: $msg');
      });

      if (Platform.isAndroid) {
        final engines = await _tts.getEngines;
        log.i('tts engines: $engines');
        if (engines is List && engines.isEmpty) {
          _lastError = 'No TextToSpeech engine installed on this device.';
          log.e(_lastError);
        }
      }

      await _tts.awaitSpeakCompletion(true);
      final langOk = await _tts.setLanguage('en-US');
      log.i('tts setLanguage(en-US) -> $langOk');
      await _tts.setSpeechRate(0.5); // Android "normal" sits low on this scale
      await _tts.setPitch(1.0);
      await _tts.setVolume(1.0);

      _ready = true;
      log.i('TtsService ready (flutter_tts)');
    } catch (e, s) {
      _lastError = e.toString();
      log.e('TtsService.init failed', e, s);
      _ready = false;
    }
  }

  /// Returns true if it believes the utterance was handed to the engine.
  Future<bool> speak(String text) async {
    final line = text.trim();
    if (line.isEmpty) return false;
    if (!_ready) await init();
    try {
      await _tts.stop();
      log.i('Nova says: "$line"');
      final result = await _tts.speak(line); // 1 = queued/started on Android
      return result == 1 || result == null;
    } catch (e, s) {
      _lastError = e.toString();
      log.e('tts speak failed', e, s);
      return false;
    }
  }

  Future<void> stop() async {
    try {
      await _tts.stop();
    } catch (_) {}
  }

  Future<void> dispose() async {
    await stop();
    _ready = false;
  }
}
