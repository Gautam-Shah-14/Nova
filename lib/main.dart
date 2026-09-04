import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:hive_flutter/hive_flutter.dart';

import 'controllers/service_controller.dart';
import 'di.dart';
import 'screens/home_screen.dart';
import 'services/llm_service.dart';
import 'services/tts_service.dart';
import 'skills/notes_skill.dart';
import 'utils/logger.dart';

/// Nova's real surface is the notification + overlay dot. The screen is a
/// status console for bring-up. Startup is deliberately fault-tolerant: any one
/// subsystem (TTS, Vosk, LLM) can fail without taking the app down.
Future<void> main() async {
  // Never let an async/platform error hard-crash the process.
  FlutterError.onError = (d) => log.e('FlutterError', d.exception, d.stack);
  PlatformDispatcher.instance.onError = (e, s) {
    log.e('uncaught', e, s);
    return true;
  };

  await runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();

    await Hive.initFlutter();
    await Hive.openBox<String>(NotesSkill.boxName);
    installDependencies();

    runApp(const NovaApp());

    unawaited(_start());
  }, (e, s) => log.e('zone', e, s));
}

Future<void> _start() async {
  final tts = Get.find<TtsService>();

  // 1. Voice out first — quick, and proves the app is alive.
  await _guard('tts.init', () => tts.init());
  await Future<void>.delayed(const Duration(milliseconds: 400));
  await _guard('tts.speak', () => tts.speak('Nova online.'));

  // 2. Permissions BEFORE anything touches the mic.
  await _guard(
      'permissions', () => Get.find<ServiceController>().requestPermissions());

  // 3. Bring up the foreground service + event wiring (no mic yet).
  await _guard('arm', () => Get.find<ServiceController>().arm());

  // 4. LLM downloads/loads in the background; keyword parser covers the gap.
  unawaited(_guard('llm.init', () => Get.find<LlmService>().init()));

  // NOTE: Vosk (offline wake word / STT) is NOT started here. It has been
  // crashing on-device (JNA native load). Start it from the status screen's
  // "Start listening" button so a failure is isolated and visible.
}

Future<void> _guard(String label, Future<void> Function() step) async {
  try {
    await step();
    log.i('startup ok: $label');
  } catch (e, s) {
    log.e('startup step failed: $label', e, s);
  }
}

class NovaApp extends StatelessWidget {
  const NovaApp({super.key});

  @override
  Widget build(BuildContext context) {
    return GetMaterialApp(
      title: 'Nova',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF2E7D32)),
        useMaterial3: true,
      ),
      home: const HomeScreen(),
    );
  }
}
