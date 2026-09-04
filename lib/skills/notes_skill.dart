import 'package:hive/hive.dart';

import '../models/parsed_intent.dart';
import '../models/skill_result.dart';
import 'skill.dart';

/// Note-to-self. Appends to a Hive box; reads back the most recent few.
/// `delete` is listed as irreversible in [NovaConfig.irreversibleIntents], so
/// it only runs after the reasoning engine's confirmation step.
class NotesSkill extends Skill {
  static const String boxName = 'nova_notes';

  @override
  String get name => 'notes';

  @override
  String get usage =>
      'note to self. args: {"text": "..."} to add; {} to read back; {"index": int} to delete';

  @override
  Set<String> get actions => {'add', 'read', 'delete'};

  Box<String> get _box => Hive.box<String>(boxName);

  @override
  Future<SkillResult> run(ParsedIntent intent) async {
    switch (intent.action) {
      case 'add':
        final text = (intent.args['text'] ?? '').toString().trim();
        if (text.isEmpty) return SkillResult.failed('Nothing to note.');
        await _box.add(text);
        return SkillResult.ok('Noted.');

      case 'read':
        final notes = _box.values.toList();
        if (notes.isEmpty) return SkillResult.ok('No notes.');
        final recent = notes.reversed.take(3).toList();
        return SkillResult.ok('Your latest notes: ${recent.join('; ')}.');

      case 'delete':
        final index = (intent.args['index'] as num?)?.toInt() ?? _box.length - 1;
        if (index < 0 || index >= _box.length) {
          return SkillResult.failed('No note at that position.');
        }
        await _box.deleteAt(index);
        return SkillResult.ok('Deleted.');

      default:
        return SkillResult.failed('notes can\'t do "${intent.action}".');
    }
  }
}
