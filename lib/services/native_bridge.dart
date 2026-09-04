import 'package:flutter/services.dart';

import '../config/nova_config.dart';
import '../models/nova_status.dart';
import '../utils/logger.dart';

/// One app with a launcher entry, from the native package query.
class InstalledApp {
  const InstalledApp(this.package, this.label);
  final String package;
  final String label;
}

/// A native event pushed up the events channel.
class NativeEvent {
  const NativeEvent(this.type, this.data);
  final String type; // 'wakeWord' | 'serviceState' | 'accessibilityState'
  final Map<String, dynamic> data;
}

/// The single seam between Dart and the Kotlin services. Everything platform-
/// specific goes through here so the rest of the app stays testable.
class NativeBridge {
  NativeBridge._()
      : _method = const MethodChannel(NovaConfig.bridgeChannel),
        _events = const EventChannel(NovaConfig.eventsChannel);

  static final NativeBridge instance = NativeBridge._();

  final MethodChannel _method;
  final EventChannel _events;

  Stream<NativeEvent>? _eventStream;

  /// wake-word hits + service/accessibility lifecycle from the native side.
  Stream<NativeEvent> events() {
    return _eventStream ??= _events.receiveBroadcastStream().map((raw) {
      final map = (raw as Map).cast<String, dynamic>();
      final type = map.remove('type')?.toString() ?? 'unknown';
      return NativeEvent(type, map);
    }).handleError((Object e) => log.e('events channel error', e));
  }

  // ── Wake-word foreground service ────────────────────────────────────────
  Future<void> startListening() => _invoke('startListening');
  Future<void> stopListening() => _invoke('stopListening');
  Future<bool> serviceRunning() async =>
      (await _invoke<bool>('serviceRunning')) ?? false;

  /// Debug trigger — makes the service capture an utterance and emit a
  /// `wakeWord` event as if the phrase had been heard.
  Future<void> simulateWake() => _invoke('simulateWake');

  Future<void> setStatus(NovaStatus status) =>
      _invoke('setStatus', {'status': status.wire});

  // ── Floating overlay dot ───────────────────────────────────────────────
  Future<bool> showOverlay() async => (await _invoke<bool>('showOverlay')) ?? false;
  Future<void> hideOverlay() => _invoke('hideOverlay');
  Future<bool> canDrawOverlays() async =>
      (await _invoke<bool>('canDrawOverlays')) ?? false;
  Future<void> openOverlaySettings() => _invoke('openOverlaySettings');

  // ── Accessibility driver ───────────────────────────────────────────────
  Future<bool> isAccessibilityConnected() async =>
      (await _invoke<bool>('isAccessibilityConnected')) ?? false;
  Future<void> openAccessibilitySettings() => _invoke('openAccessibilitySettings');

  // ── Generic app control ────────────────────────────────────────────────
  Future<List<InstalledApp>> listLaunchableApps() async {
    final raw = await _invoke<List<dynamic>>('listLaunchableApps') ?? const [];
    return raw
        .map((e) => (e as Map).cast<String, dynamic>())
        .map((m) => InstalledApp(m['package'].toString(), m['label'].toString()))
        .toList();
  }

  Future<bool> launchApp(String package) async =>
      (await _invoke<bool>('launchApp', {'package': package})) ?? false;

  Future<bool> openUrl(String url) async =>
      (await _invoke<bool>('openUrl', {'url': url})) ?? false;

  // ── Device info ────────────────────────────────────────────────────────
  Future<int> deviceRamMb() async => (await _invoke<int>('deviceRamMb')) ?? 0;

  Future<T?> _invoke<T>(String method, [Map<String, dynamic>? args]) async {
    try {
      return await _method.invokeMethod<T>(method, args);
    } on PlatformException catch (e) {
      log.e('native $method failed', e);
      return null;
    } on MissingPluginException {
      log.w('native $method unavailable (not running on device?)');
      return null;
    }
  }
}
