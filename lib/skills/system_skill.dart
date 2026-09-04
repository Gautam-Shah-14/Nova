import 'package:battery_plus/battery_plus.dart';

import '../models/parsed_intent.dart';
import '../models/skill_result.dart';
import 'skill.dart';

/// Battery, volume, flashlight — the "trivial, standard APIs" bucket from the
/// design doc. Phase 1 ships `battery` end to end; volume/flashlight are stubbed
/// until Phase 2 ("battery/system controls").
class SystemSkill extends Skill {
  SystemSkill({Battery? battery}) : _battery = battery ?? Battery();

  final Battery _battery;

  @override
  String get name => 'system';

  @override
  String get usage =>
      'device controls. args: {} for battery; {"level": 0-100} or {"delta": int} for volume; {"on": bool} for flashlight';

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

      case 'volume':
      case 'flashlight':
        // TODO(nova): native handlers (Phase 2 — "battery/system controls").
        return SkillResult.failed('${intent.action} control isn\'t wired up yet.');

      default:
        return SkillResult.failed('system can\'t do "${intent.action}".');
    }
  }
}
