import '../models/parsed_intent.dart';
import '../models/skill_result.dart';

/// A skill is one capability Nova can dispatch to. Keep them small and
/// single-purpose — the LLM picks between them by [name].
abstract class Skill {
  /// Matches `ParsedIntent.skill`.
  String get name;

  /// One line the prompt builder shows the LLM so it knows this skill exists
  /// and what `args` it takes.
  String get usage;

  /// Actions this skill accepts (the `action` half of the intent).
  Set<String> get actions;

  /// Run it. [intent.args] is already validated to the extent the dispatcher
  /// can — allow-lists and confirmations happen before this is called.
  Future<SkillResult> run(ParsedIntent intent);

  bool handles(ParsedIntent intent) =>
      intent.skill == name && actions.contains(intent.action);
}
