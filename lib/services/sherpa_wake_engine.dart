import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa_onnx;

import '../utils/logger.dart';

/// Continuous, free, offline wake-word spotting for "Tony". Decodes raw mic
/// samples directly — via `record`'s PCM stream — into a tiny bundled
/// keyword-spotting model, rather than opening an Android "recognition
/// session" the way `SpeechRecognizer` does. Recording audio never requires
/// audio focus (that's a playback-arbitration concept), so unlike the
/// speech_to_text-only loop, this doesn't duck or pause other apps' audio
/// while it's just waiting to be woken. `speech_to_text` still captures the
/// actual command afterward.
///
/// Entirely self-contained: model files are bundled in the APK
/// (assets/sherpa_kws/), no account or network needed. If anything here
/// fails to initialise, [init] returns false and [WakeWordService] falls
/// back to its speech_to_text-only loop — nothing else breaks.
class SherpaWakeEngine {
  static const _sampleRate = 16000;
  static const _assetDir = 'assets/sherpa_kws';
  static bool _bindingsReady = false;

  sherpa_onnx.KeywordSpotter? _spotter;
  sherpa_onnx.OnlineStream? _stream;
  final AudioRecorder _recorder = AudioRecorder();
  StreamSubscription<Uint8List>? _audioSub;

  bool _ready = false;
  bool _listening = false;

  bool get available => _ready;

  Future<bool> init(void Function() onWake) async {
    try {
      if (!_bindingsReady) {
        sherpa_onnx.initBindings();
        _bindingsReady = true;
      }

      final dir = await getApplicationSupportDirectory();
      final modelDir = Directory('${dir.path}/sherpa_kws');
      await modelDir.create(recursive: true);

      final encoder = await _extractAsset('encoder.onnx', modelDir);
      final decoder = await _extractAsset('decoder.onnx', modelDir);
      final joiner = await _extractAsset('joiner.onnx', modelDir);
      final tokens = await _extractAsset('tokens.txt', modelDir);
      final keywords = await _extractAsset('keywords.txt', modelDir);

      final config = sherpa_onnx.KeywordSpotterConfig(
        model: sherpa_onnx.OnlineModelConfig(
          transducer: sherpa_onnx.OnlineTransducerModelConfig(
            encoder: encoder,
            decoder: decoder,
            joiner: joiner,
          ),
          tokens: tokens,
          numThreads: 1,
          provider: 'cpu',
          debug: false,
        ),
        keywordsFile: keywords,
      );

      _spotter = sherpa_onnx.KeywordSpotter(config);
      _stream = _spotter!.createStream();
      _onWake = onWake;
      _ready = true;
      log.i('SherpaWakeEngine ready');
      return true;
    } catch (e, s) {
      log.e('SherpaWakeEngine init failed — falling back to speech_to_text only', e, s);
      _ready = false;
      return false;
    }
  }

  void Function()? _onWake;

  Future<String> _extractAsset(String name, Directory dir) async {
    final file = File('${dir.path}/$name');
    if (!await file.exists()) {
      final data = await rootBundle.load('$_assetDir/$name');
      await file.writeAsBytes(data.buffer.asUint8List(), flush: true);
    }
    return file.path;
  }

  Future<void> start() async {
    if (!_ready || _listening) return;
    try {
      if (!await _recorder.hasPermission()) {
        log.w('SherpaWakeEngine: no mic permission');
        return;
      }
      final stream = await _recorder.startStream(const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: _sampleRate,
        numChannels: 1,
        androidConfig: AndroidRecordConfig(audioSource: AndroidAudioSource.voiceRecognition),
      ));
      _listening = true;
      _audioSub = stream.listen(_onPcmChunk, onError: (Object e) {
        log.w('SherpaWakeEngine audio stream error: $e');
      });
    } catch (e, s) {
      log.e('SherpaWakeEngine.start failed', e, s);
      _listening = false;
    }
  }

  void _onPcmChunk(Uint8List bytes) {
    final spotter = _spotter;
    final stream = _stream;
    if (spotter == null || stream == null) return;

    // PCM16 little-endian bytes -> Float32 normalised to [-1, 1].
    final samples = Float32List(bytes.length ~/ 2);
    final data = ByteData.sublistView(bytes);
    for (var i = 0; i < samples.length; i++) {
      samples[i] = data.getInt16(i * 2, Endian.little) / 32768.0;
    }

    try {
      stream.acceptWaveform(samples: samples, sampleRate: _sampleRate);
      while (spotter.isReady(stream)) {
        spotter.decode(stream);
      }
      final keyword = spotter.getResult(stream).keyword;
      if (keyword.isNotEmpty) {
        spotter.reset(stream);
        _onWake?.call();
      }
    } catch (e, s) {
      log.e('SherpaWakeEngine decode failed', e, s);
    }
  }

  Future<void> stop() async {
    if (!_listening) return;
    _listening = false;
    await _audioSub?.cancel();
    _audioSub = null;
    try {
      await _recorder.stop();
    } catch (e) {
      log.w('SherpaWakeEngine stop failed: $e');
    }
  }

  Future<void> dispose() async {
    await stop();
    try {
      _stream?.free();
      _spotter?.free();
    } catch (_) {}
    try {
      _recorder.dispose();
    } catch (_) {}
    _ready = false;
  }
}
