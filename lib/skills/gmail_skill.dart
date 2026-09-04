import '../models/parsed_intent.dart';
import '../models/skill_result.dart';
import '../services/accessibility_service.dart';
import '../services/native_bridge.dart';
import 'skill.dart';

/// Thin config on top of the generic Accessibility driver — no OAuth/API, Nova
/// reads and drives the Gmail app UI directly (same mechanism as WhatsApp).
///
/// Trade-off vs the official API: more fragile if Gmail's layout changes, and
/// `send` can't be validated the way a structured API call could — so it's in
/// [NovaConfig.irreversibleIntents] and always hits the confirmation step first.
class GmailSkill extends Skill {
  GmailSkill({AccessibilityService? a11y, NativeBridge? bridge})
      : a11y = a11y ?? AccessibilityService(),
        _bridge = bridge ?? NativeBridge.instance;

  final AccessibilityService a11y;
  final NativeBridge _bridge;

  static const _package = 'com.google.android.gm';

  @override
  String get name => 'gmail';

  @override
  String get usage =>
      'compose/send mail via the Gmail app UI. '
      'args: {"to": "...", "subject": "...", "body": "..."}';

  @override
  Set<String> get actions => {'send', 'open'};

  @override
  Future<SkillResult> run(ParsedIntent intent) async {
    if (!await _bridge.launchApp(_package)) {
      return SkillResult.failed('Gmail isn\'t installed.');
    }
    if (intent.action == 'open') return SkillResult.ok('Opened Gmail.');

    if (!await a11y.isConnected()) {
      return SkillResult.failed(
          'Enable Nova\'s accessibility service in Android Settings first.');
    }

    final to = (intent.args['to'] ?? '').toString().trim();
    final subject = (intent.args['subject'] ?? '').toString().trim();
    final body = (intent.args['body'] ?? '').toString().trim();
    if (to.isEmpty || body.isEmpty) {
      return SkillResult.failed('Need at least a recipient and a body.');
    }

    await _settle();
    if (!(await a11y.tapText('Compose')).ok) {
      return SkillResult.failed('Couldn\'t start a new email.');
    }
    await _settle();
    await a11y.typeInto(target: 'To', text: to);
    if (subject.isNotEmpty) await a11y.typeInto(target: 'Subject', text: subject);
    await a11y.typeInto(target: 'Compose email', text: body);
    await _settle(short: true);

    final sent = await a11y.tapText('Send');
    return sent.ok
        ? SkillResult.ok('Email sent to $to.')
        : SkillResult.failed('Drafted it, but couldn\'t hit send.');
  }

  Future<void> _settle({bool short = false}) =>
      Future<void>.delayed(Duration(milliseconds: short ? 350 : 900));
}
