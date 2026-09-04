import 'package:flutter/services.dart';

import '../config/nova_config.dart';
import '../utils/logger.dart';

/// Outcome of an accessibility primitive. [connected] is false when the user
/// hasn't enabled Nova's accessibility service yet — skills use that to prompt
/// for it instead of reporting a generic failure.
class A11yResult {
  const A11yResult({required this.connected, required this.ok});
  final bool connected;
  final bool ok;

  static const notEnabled = A11yResult(connected: false, ok: false);
}

/// Dart face of the single generic Accessibility driver ([AccessibilityBridge]
/// on the native side). Every "operate another app" skill composes these.
class AccessibilityService {
  AccessibilityService() : _channel = const MethodChannel(NovaConfig.a11yChannel);

  final MethodChannel _channel;

  Future<bool> isConnected() async {
    final r = await _call('isConnected');
    return r.connected;
  }

  Future<bool> findText(String text) async {
    final r = await _call('findText', {'text': text});
    return r.connected && r.ok;
  }

  Future<A11yResult> tapText(String text) => _call('tapText', {'text': text});

  Future<A11yResult> typeInto({String? target, required String text}) =>
      _call('typeInto', {'target': target, 'text': text});

  Future<A11yResult> back() => _call('back');
  Future<A11yResult> home() => _call('home');

  Future<A11yResult> _call(String method, [Map<String, dynamic>? args]) async {
    try {
      final raw = await _channel.invokeMapMethod<String, dynamic>(method, args);
      if (raw == null) return A11yResult.notEnabled;
      return A11yResult(
        connected: raw['connected'] == true,
        ok: raw['ok'] == true || raw['found'] == true,
      );
    } on PlatformException catch (e) {
      log.e('a11y $method failed', e);
      return A11yResult.notEnabled;
    } on MissingPluginException {
      return A11yResult.notEnabled;
    }
  }
}
