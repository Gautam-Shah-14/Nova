import 'dart:io';

import 'package:dio/dio.dart';
import 'package:get/get.dart' hide Response, FormData, MultipartFile;

import '../config/nova_config.dart';
import '../utils/logger.dart';
import 'model_store.dart';
import 'native_bridge.dart';

enum DownloadState { idle, running, done, failed }

/// Streams the GGUF LLM weight to device storage on first run. Resumable — a
/// partial `.part` file is continued with a Range request. Progress is exposed
/// reactively so the foreground-service notification can show it.
class ModelDownloader {
  ModelDownloader({ModelStore? store, Dio? dio, NativeBridge? bridge})
      : _store = store ?? ModelStore(),
        _dio = dio ?? Dio(),
        _bridge = bridge ?? NativeBridge.instance;

  final ModelStore _store;
  final Dio _dio;
  final NativeBridge _bridge;

  /// Which weight this device gets, and its target path. Public so the LLM
  /// service loads the same file the downloader fetched.
  Future<({String file, String url})> plan() async {
    final ramMb = await _bridge.deviceRamMb();
    final usePrimary = ramMb == 0 || ramMb >= NovaConfig.llmFallbackRamThresholdMb;
    return usePrimary
        ? (file: NovaConfig.llmPrimaryFile, url: NovaConfig.llmDownloadUrl)
        : (file: NovaConfig.llmFallbackFile, url: NovaConfig.llmFallbackDownloadUrl);
  }

  final Rx<DownloadState> state = DownloadState.idle.obs;
  final RxDouble progress = 0.0.obs; // 0..1
  final RxString detail = ''.obs;

  CancelToken? _cancel;

  /// Ensures the right LLM weight for this device is on disk, downloading it if
  /// missing. Returns the local path on success, null on failure.
  Future<String?> ensureLlmModel() async {
    final p = await plan();
    final target = await _store.path(p.file);
    if (await File(target).exists()) {
      state.value = DownloadState.done;
      progress.value = 1;
      return target;
    }
    final ok = await _download(p.url, target);
    return ok ? target : null;
  }

  Future<bool> _download(String url, String targetPath) async {
    if (state.value == DownloadState.running) return false;
    state.value = DownloadState.running;
    progress.value = 0;
    _cancel = CancelToken();

    final target = File(targetPath);
    final part = File('$targetPath.part');
    await target.parent.create(recursive: true);

    var existing = 0;
    if (await part.exists()) existing = await part.length();

    try {
      final resp = await _dio.get<ResponseBody>(
        url,
        options: Options(
          responseType: ResponseType.stream,
          followRedirects: true,
          headers: existing > 0 ? {'range': 'bytes=$existing-'} : null,
          validateStatus: (s) => s != null && s < 400,
        ),
        cancelToken: _cancel,
      );

      final total = _totalBytes(resp, existing);
      final sink = part.openWrite(mode: FileMode.append);
      var received = existing;

      await for (final chunk in resp.data!.stream) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) {
          progress.value = received / total;
          detail.value = '${_mb(received)} / ${_mb(total)} MB';
        } else {
          detail.value = '${_mb(received)} MB';
        }
      }
      await sink.flush();
      await sink.close();

      await part.rename(targetPath);
      state.value = DownloadState.done;
      progress.value = 1;
      log.i('LLM model downloaded -> $targetPath');
      return true;
    } catch (e, s) {
      state.value = DownloadState.failed;
      detail.value = e.toString();
      log.e('model download failed', e, s);
      return false;
    }
  }

  void cancel() => _cancel?.cancel('cancelled');

  int _totalBytes(Response<ResponseBody> resp, int existing) {
    final len = resp.data?.contentLength ?? -1;
    if (len <= 0) return -1;
    return len + existing;
  }

  String _mb(int bytes) => (bytes / (1024 * 1024)).toStringAsFixed(0);
}
