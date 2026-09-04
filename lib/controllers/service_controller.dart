import 'dart:async';

import 'package:get/get.dart';
import 'package:permission_handler/permission_handler.dart';

import '../config/nova_config.dart';
import '../models/nova_status.dart';
import '../models/wake_event.dart';
import '../services/native_bridge.dart';
import '../services/tts_service.dart';
import '../services/wake_word_service.dart';
import '../utils/logger.dart';
import 'queue_controller.dart';
import 'status_controller.dart';

/// Owns Nova's lifecycle: request permissions, arm the wake-word listener,
/// route each recognised command into the task queue, and handle the
/// notification action buttons. No screens.
class ServiceController extends GetxController {
  ServiceController({
    required this.wakeWord,
    required this.queue,
    required this.statusController,
    required this.tts,
    NativeBridge? bridge,
  }) : _bridge = bridge ?? NativeBridge.instance;

  final WakeWordService wakeWord;
  final QueueController queue;
  final StatusController statusController;
  final TtsService tts;
  final NativeBridge _bridge;

  final RxBool micGranted = false.obs;
  final RxBool overlayGranted = false.obs;
  final RxBool notificationsGranted = false.obs;
  final RxBool accessibilityConnected = false.obs;
  final RxBool speechRecognitionReady = false.obs;
  final RxBool listening = false.obs;
  final RxBool bootstrapped = false.obs;

  StreamSubscription<WakeEvent>? _wakeSub;
  StreamSubscription<NativeEvent>? _eventSub;

  /// Screen-off idle timer — fires [pause] after [NovaConfig.idleSleepTimeout];
  /// [resume] on unlock. Manual pause is respected: [_manuallyPaused] blocks the
  /// unlock auto-resume.
  Timer? _idleTimer;
  bool _manuallyPaused = false;

  /// Step 1 of startup — ask for every permission Nova needs. Called from
  /// main() before anything touches the mic, so the prompts always appear.
  Future<void> requestPermissions() async {
    _listenForNativeEvents();
    await _requestPermissions();
  }

  /// Step 2 — foreground service + event wiring, then starts listening if the
  /// mic is granted. [enableListening] stays available as a manual retry (the
  /// notification/screen can lose the recognizer if the OS reclaims the mic).
  Future<void> arm() async {
    _wakeSub ??= wakeWord.onWake.listen((event) {
      if (event.hasCommand) queue.enqueue(text: event.command!);
    });
    try {
      await _bridge.startListening(); // FGS: notification + wake lock
    } catch (_) {}
    if (overlayGranted.value) {
      try {
        await _bridge.showOverlay();
      } catch (_) {}
    }
    await enableListening();
    bootstrapped.value = true;
    log.i('Nova armed — listening=${listening.value}');
  }

  /// Starts (or restarts) the speech recognizer. Returns null on success, an
  /// error string on failure.
  Future<String?> enableListening() async {
    if (!micGranted.value) {
      await statusController.sleeping();
      return 'Microphone permission not granted.';
    }
    try {
      await wakeWord.start();
      speechRecognitionReady.value = wakeWord.speechAvailable;
      listening.value = wakeWord.isRunning;
      if (wakeWord.speechAvailable) {
        await statusController.available();
        return null;
      }
      await statusController.sleeping();
      return 'Speech recognition did not initialise on this device.';
    } catch (e, s) {
      log.e('enableListening failed', e, s);
      speechRecognitionReady.value = false;
      listening.value = false;
      await statusController.sleeping();
      return 'Listening failed: $e';
    }
  }

  /// Re-poll everything — call when the app resumes (permissions granted in
  /// Settings won't reflect until re-checked).
  Future<void> refreshStatus() async {
    micGranted.value = await Permission.microphone.isGranted;
    notificationsGranted.value = await Permission.notification.isGranted;
    try {
      overlayGranted.value = await _bridge.canDrawOverlays();
      accessibilityConnected.value = await _bridge.isAccessibilityConnected();
    } catch (_) {}
    speechRecognitionReady.value = wakeWord.speechAvailable;
    listening.value = wakeWord.isRunning;
  }

  /// Debug: next spoken utterance is treated as a command, no wake word needed.
  Future<void> simulateWake() => wakeWord.simulate();

  /// Restarts the wake-word listener (foreground service + recognizer) only.
  /// Deliberately does NOT touch [LlmService] — the AI model, once downloaded
  /// and loaded, must never be reloaded or re-fetched by this.
  Future<String?> restartListening() async {
    log.i('restarting listening service');
    await wakeWord.stop();
    listening.value = false;
    speechRecognitionReady.value = false;
    return enableListening();
  }

  /// Notification action buttons route here via a native `control` event.
  Future<void> _handleControl(String? cmd) async {
    switch (cmd) {
      case 'pause':
        await pause(manual: true);
      case 'resume':
        await resume();
      case 'talk':
        await simulateWake();
      case 'test':
        await tts.speak('Nova here. Voice output is working.');
    }
  }

  Future<void> pause({bool manual = false}) async {
    if (manual) _manuallyPaused = true;
    _idleTimer?.cancel();
    await wakeWord.stop();
    listening.value = false;
    await statusController.sleeping();
  }

  Future<void> resume() async {
    _manuallyPaused = false;
    _idleTimer?.cancel();
    if (!micGranted.value) return;
    await wakeWord.start();
    speechRecognitionReady.value = wakeWord.speechAvailable;
    listening.value = wakeWord.isRunning;
    if (statusController.value == NovaStatus.sleeping) {
      await statusController.available();
    }
  }

  /// Debug screen: type or paste a command and run it through the full pipeline.
  void runTextCommand(String text) {
    final t = text.trim();
    if (t.isEmpty) return;
    queue.enqueue(text: t);
  }

  Future<void> _requestPermissions() async {
    final mic = await Permission.microphone.request();
    micGranted.value = mic.isGranted;

    if (await Permission.notification.isDenied) {
      notificationsGranted.value =
          (await Permission.notification.request()).isGranted;
    } else {
      notificationsGranted.value = true;
    }

    // For "call <contact>" — looking a name up before dialing.
    await Permission.contacts.request();

    overlayGranted.value = await _bridge.canDrawOverlays();
    if (!overlayGranted.value) {
      // Can't be granted from a dialog — send the user to Settings once.
      await _bridge.openOverlaySettings();
      overlayGranted.value = await _bridge.canDrawOverlays();
    }

    accessibilityConnected.value = await _bridge.isAccessibilityConnected();
    if (!accessibilityConnected.value) {
      // Same pattern as overlay: can't be granted from a dialog, so send the
      // user straight to the settings screen instead of making them find it.
      //
      // Android 13+ note: a sideloaded app's toggle here starts "Restricted"
      // (greyed out) until the user allows it from App info's overflow menu
      // ⋮ → "Allow restricted settings". `openAccessibilitySettings()` can't
      // do that step for them — it's an anti-malware guard Android requires a
      // real tap for — so if the toggle looks disabled, that's the fix.
      await _bridge.openAccessibilitySettings();
      accessibilityConnected.value = await _bridge.isAccessibilityConnected();
    }
    log.i('perms — mic:${micGranted.value} overlay:${overlayGranted.value} '
        'notif:${notificationsGranted.value} a11y:${accessibilityConnected.value}');
  }

  void _listenForNativeEvents() {
    _eventSub = _bridge.events().listen((e) {
      switch (e.type) {
        case 'accessibilityState':
          accessibilityConnected.value = e.data['connected'] == true;
        case 'serviceState':
          if (e.data['running'] != true &&
              statusController.value != NovaStatus.sleeping) {
            log.w('native listener stopped unexpectedly');
          }
        case 'screenState':
          _onScreenState(e.data['state']?.toString());
        case 'control':
          _handleControl(e.data['cmd']?.toString());
      }
    });
  }

  void _onScreenState(String? state) {
    switch (state) {
      case 'off':
        if (_manuallyPaused || !micGranted.value) return;
        _idleTimer?.cancel();
        _idleTimer = Timer(NovaConfig.idleSleepTimeout, () {
          log.i('idle timeout — sleeping');
          pause();
        });
      case 'present':
        _idleTimer?.cancel();
        if (!_manuallyPaused) resume();
    }
  }

  @override
  void onClose() {
    _idleTimer?.cancel();
    _wakeSub?.cancel();
    _eventSub?.cancel();
    wakeWord.dispose();
    super.onClose();
  }
}
