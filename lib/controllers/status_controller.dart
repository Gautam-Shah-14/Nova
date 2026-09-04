import 'package:get/get.dart';

import '../models/nova_status.dart';
import '../services/native_bridge.dart';
import '../utils/logger.dart';

/// Single source of truth for Nova's state. Whatever it's set to is pushed to
/// both native render targets (notification icon + overlay dot) in one call.
class StatusController extends GetxController {
  StatusController({NativeBridge? bridge}) : _bridge = bridge ?? NativeBridge.instance;

  final NativeBridge _bridge;

  final Rx<NovaStatus> status = NovaStatus.sleeping.obs;

  NovaStatus get value => status.value;

  Future<void> set(NovaStatus next) async {
    if (status.value == next) return;
    status.value = next;
    log.d('status -> ${next.name}');
    await _bridge.setStatus(next);
  }

  Future<void> available() => set(NovaStatus.available);
  Future<void> working() => set(NovaStatus.working);
  Future<void> sleeping() => set(NovaStatus.sleeping);
}
