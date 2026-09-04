import '../models/parsed_intent.dart';
import '../models/skill_result.dart';
import '../services/accessibility_service.dart';
import 'skill.dart';

/// The generic Accessibility-based read/tap/type driver, reused by Gmail,
/// WhatsApp and any other app instead of one-off per-app integrations. Exposed
/// directly as a skill so the LLM can drive arbitrary apps step by step.
class AppControlSkill extends Skill {
  AppControlSkill({AccessibilityService? a11y})
      : a11y = a11y ?? AccessibilityService();

  final AccessibilityService a11y;

  @override
  String get name => 'app_control';

  @override
  String get usage =>
      'drive the on-screen UI of the foreground app. '
      'args: {"text": "..."} for tap/find; {"text": "...", "into": "<field label>"} for type';

  @override
  Set<String> get actions => {'tap', 'type', 'find', 'back', 'home'};

  static const _needEnable =
      'Enable Nova\'s accessibility service in Android Settings first.';

  @override
  Future<SkillResult> run(ParsedIntent intent) async {
    if (!await a11y.isConnected()) return SkillResult.failed(_needEnable);

    switch (intent.action) {
      case 'find':
        final found = await a11y.findText(_text(intent));
        return found
            ? SkillResult.ok('Found "${_text(intent)}".')
            : SkillResult.failed('No "${_text(intent)}" on screen.');

      case 'tap':
        final r = await a11y.tapText(_text(intent));
        return r.ok
            ? SkillResult.ok('Tapped "${_text(intent)}".')
            : SkillResult.failed('Couldn\'t tap "${_text(intent)}".');

      case 'type':
        final r = await a11y.typeInto(
          target: intent.args['into']?.toString(),
          text: _text(intent),
        );
        return r.ok
            ? SkillResult.ok('Typed it in.')
            : SkillResult.failed('Couldn\'t find a field to type into.');

      case 'back':
        await a11y.back();
        return SkillResult.ok('Back.');

      case 'home':
        await a11y.home();
        return SkillResult.ok('Home.');

      default:
        return SkillResult.failed('app_control can\'t do "${intent.action}".');
    }
  }

  String _text(ParsedIntent intent) => (intent.args['text'] ?? '').toString();
}
