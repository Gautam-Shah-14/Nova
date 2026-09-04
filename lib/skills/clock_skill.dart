import '../models/parsed_intent.dart';
import '../models/skill_result.dart';
import 'skill.dart';

/// Time and date. Pure Dart, always works — handy as the "is the whole pipeline
/// alive?" check on device.
class ClockSkill extends Skill {
  @override
  String get name => 'clock';

  @override
  String get usage => 'current time or date. args: {} (action picks which)';

  @override
  Set<String> get actions => {'time', 'date'};

  @override
  Future<SkillResult> run(ParsedIntent intent) async {
    final now = DateTime.now();
    if (intent.action == 'date') {
      const months = [
        'January', 'February', 'March', 'April', 'May', 'June', 'July',
        'August', 'September', 'October', 'November', 'December',
      ];
      const days = [
        'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday',
        'Saturday', 'Sunday',
      ];
      return SkillResult.ok(
        '${days[now.weekday - 1]}, ${months[now.month - 1]} ${now.day}.',
      );
    }

    final h24 = now.hour;
    final h12 = h24 % 12 == 0 ? 12 : h24 % 12;
    final ampm = h24 < 12 ? 'AM' : 'PM';
    final mm = now.minute.toString().padLeft(2, '0');
    return SkillResult.ok('It\'s $h12:$mm $ampm.');
  }
}
