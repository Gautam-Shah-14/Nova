import '../models/parsed_intent.dart';
import '../utils/logger.dart';
import 'app_control_skill.dart';
import 'app_launcher_skill.dart';
import 'clock_skill.dart';
import 'notes_skill.dart';
import 'skill.dart';
import 'system_skill.dart';
import 'whatsapp_skill.dart';

/// Holds the installed skills and resolves an intent to one. Registered with
/// GetX so the dispatcher can `Get.find()` it.
class SkillRegistry {
  SkillRegistry({List<Skill>? skills})
      : _skills = skills ??
            <Skill>[
              SystemSkill(),
              AppLauncherSkill(),
              ClockSkill(),
              NotesSkill(),
              AppControlSkill(),
              WhatsAppSkill(),
            ];

  final List<Skill> _skills;

  List<Skill> get all => List.unmodifiable(_skills);

  Skill? resolve(ParsedIntent intent) {
    for (final skill in _skills) {
      if (skill.handles(intent)) return skill;
    }
    log.w('No skill for ${intent.qualifiedName}');
    return null;
  }

  /// The block handed to the LLM so it only ever picks a skill that exists.
  String promptCatalog() {
    final buf = StringBuffer('Available skills:\n');
    for (final skill in _skills) {
      buf.writeln('- ${skill.name} (${skill.actions.join(', ')}): ${skill.usage}');
    }
    return buf.toString();
  }
}
