import 'package:battery_plus/battery_plus.dart';

import '../models/parsed_intent.dart';
import '../models/skill_result.dart';
import '../services/native_bridge.dart';
import 'skill.dart';

/// Battery, volume, flashlight — the "trivial, standard APIs" bucket from the
/// design doc.
class SystemSkill extends Skill {
  SystemSkill({Battery? battery, NativeBridge? bridge})
      : _battery = battery ?? Battery(),
        _bridge = bridge ?? NativeBridge.instance;

  final Battery _battery;
  final NativeBridge _bridge;

  @override
  String get name => 'system';

  @override
  String get usage =>
      'device controls. args: {} for battery; {"delta": int} for volume (>0 up, <0 down, 0 mute); {"on": bool} for flashlight';

  @override
  Set<String> get actions => {'battery', 'volume', 'flashlight'};

  @override
  Future<SkillResult> run(ParsedIntent intent) async {
    switch (intent.action) {
      case 'battery':
        try {
          final pct = await _battery.batteryLevel;
          final state = await _battery.batteryState;
          final charging = state == BatteryState.charging || state == BatteryState.full;
          return SkillResult.ok(
            'Battery is at $pct percent${charging ? ', charging' : ''}.',
          );
        } catch (_) {
          return SkillResult.failed("Couldn't read the battery.");
        }

      case 'flashlight':
        final on = intent.args['on'] != false; // default true if unspecified
        final ok = await _bridge.setFlashlight(on);
        return ok
            ? SkillResult.ok(on ? 'Flashlight on.' : 'Flashlight off.')
            : SkillResult.failed("Couldn't reach the flashlight.");

      case 'volume':
        final delta = (intent.args['delta'] as num?)?.toInt() ?? 0;
        final ok = await _bridge.adjustVolume(delta);
        if (!ok) return SkillResult.failed("Couldn't change the volume.");
        return SkillResult.ok(
          delta == 0 ? 'Muted.' : (delta > 0 ? 'Volume up.' : 'Volume down.'),
        );

      default:
        return SkillResult.failed('system can\'t do "${intent.action}".');
    }
  }
}
