import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../config/nova_config.dart';
import '../utils/logger.dart';
import 'native_bridge.dart';

/// Which LLM weight to load, decided from device RAM.
enum LlmChoice { primary, fallback }

/// Resolves and validates the on-device model files. Nova never bundles the
/// GGUF/whisper weights in the APK (too big) — they're sideloaded to
/// `<appSupport>/models/` and this class reports what's actually present.
class ModelStore {
  ModelStore({NativeBridge? bridge}) : _bridge = bridge ?? NativeBridge.instance;

  final NativeBridge _bridge;

  Directory? _root;

  Future<Directory> _modelsDir() async {
    if (_root != null) return _root!;
    final base = await getApplicationSupportDirectory();
    final dir = Directory(p.join(base.path, 'models'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return _root = dir;
  }

  Future<String> path(String relative) async =>
      p.join((await _modelsDir()).path, relative);

  Future<bool> _exists(String relative) async {
    final f = File(await path(relative));
    return f.exists();
  }

  Future<String?> whisperModelPath() async {
    final ok = await _exists(NovaConfig.whisperModelFile);
    if (!ok) log.w('whisper model not found: ${NovaConfig.whisperModelFile}');
    return ok ? path(NovaConfig.whisperModelFile) : null;
  }

  /// Picks primary (3B) unless the device is under the RAM threshold or the
  /// primary file is simply missing.
  Future<({LlmChoice choice, String? path})> resolveLlm() async {
    final ramMb = await _bridge.deviceRamMb();
    final primaryPresent = await _exists(NovaConfig.llmPrimaryFile);
    final fallbackPresent = await _exists(NovaConfig.llmFallbackFile);

    final wantPrimary =
        primaryPresent && ramMb >= NovaConfig.llmFallbackRamThresholdMb;

    if (wantPrimary) {
      return (choice: LlmChoice.primary, path: await path(NovaConfig.llmPrimaryFile));
    }
    if (fallbackPresent) {
      log.i('LLM: using fallback (ram=${ramMb}MB, primary=$primaryPresent)');
      return (choice: LlmChoice.fallback, path: await path(NovaConfig.llmFallbackFile));
    }
    log.w('LLM: no model file present');
    return (choice: LlmChoice.fallback, path: null);
  }

  Future<Map<String, bool>> inventory() async => {
        'whisper': await _exists(NovaConfig.whisperModelFile),
        'llmPrimary': await _exists(NovaConfig.llmPrimaryFile),
        'llmFallback': await _exists(NovaConfig.llmFallbackFile),
      };
}
