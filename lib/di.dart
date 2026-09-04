import 'package:get/get.dart';

import 'controllers/queue_controller.dart';
import 'controllers/service_controller.dart';
import 'controllers/status_controller.dart';
import 'services/dispatcher.dart';
import 'services/llm_service.dart';
import 'services/model_downloader.dart';
import 'services/model_store.dart';
import 'services/reasoning_engine.dart';
import 'services/tts_service.dart';
import 'services/vosk_service.dart';
import 'services/wake_word_service.dart';
import 'skills/skill_registry.dart';

/// Wires the object graph. Called once from main(). Order matters — leaves
/// first, controllers last.
void installDependencies() {
  final models = Get.put(ModelStore(), permanent: true);
  final downloader = Get.put(ModelDownloader(store: models), permanent: true);
  final registry = Get.put(SkillRegistry(), permanent: true);

  final tts = Get.put(TtsService(), permanent: true);
  final vosk = Get.put(VoskService(), permanent: true);
  final llm = Get.put(
    LlmService(registry: registry, models: models, downloader: downloader),
    permanent: true,
  );
  final reasoning = Get.put(ReasoningEngine(), permanent: true);
  final dispatcher = Get.put(Dispatcher(registry: registry), permanent: true);

  final status = Get.put(StatusController(), permanent: true);
  final wakeWord = Get.put(
    WakeWordService(status: status, vosk: vosk),
    permanent: true,
  );
  final queue = Get.put(
    QueueController(
      llm: llm,
      reasoning: reasoning,
      dispatcher: dispatcher,
      tts: tts,
      statusController: status,
    ),
    permanent: true,
  );
  Get.put(
    ServiceController(
      wakeWord: wakeWord,
      queue: queue,
      statusController: status,
      tts: tts,
    ),
    permanent: true,
  );
}
