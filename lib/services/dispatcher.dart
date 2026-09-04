import '../models/parsed_intent.dart';
import '../models/reasoning_result.dart';
import '../models/skill_result.dart';
import '../skills/skill_registry.dart';
import '../utils/logger.dart';

/// Turns a reasoned intent into an executed skill. Validates against the skill
/// set and enforces hard allow-lists — independent of whatever the LLM said.
///
/// The reasoning engine has already run; [dispatch] trusts its verdict on
/// blocking/confirmation and does the last-mile schema check.
class Dispatcher {
  Dispatcher({required this.registry});

  final SkillRegistry registry;

  Future<SkillResult> dispatch(ReasoningResult reasoning) async {
    if (reasoning.blocked) {
      return SkillResult.failed(reasoning.blockedReason!);
    }

    final ParsedIntent intent = reasoning.intent;

    if (intent.needsClarification) {
      return SkillResult.failed(intent.clarifyingQuestion!);
    }

    final skill = registry.resolve(intent);
    if (skill == null) {
      return SkillResult.failed("I don't have a skill for that.");
    }

    log.i('dispatch ${intent.qualifiedName} -> ${skill.name}  (${reasoning.rationale})');
    try {
      return await skill.run(intent);
    } catch (e, s) {
      log.e('skill ${skill.name} threw', e, s);
      return SkillResult.failed('That skill hit an error.');
    }
  }
}
