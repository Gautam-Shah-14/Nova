import '../models/parsed_intent.dart';
import '../models/skill_result.dart';
import '../services/native_bridge.dart';
import 'skill.dart';

/// "Call `<name>`" — looks the name up against the phone's own contacts (the
/// same autocomplete index Android's dialer uses) and opens the dialer with
/// the number ready. Deliberately `ACTION_DIAL`, not `ACTION_CALL`: Nova
/// pre-fills, you tap the button — no CALL_PHONE permission, and a misheard
/// name can't place a call on its own.
class PhoneSkill extends Skill {
  PhoneSkill({NativeBridge? bridge}) : _bridge = bridge ?? NativeBridge.instance;

  final NativeBridge _bridge;

  @override
  String get name => 'phone';

  @override
  String get usage => 'call a contact or number. args: {"query": "<contact name or number>"}';

  @override
  Set<String> get actions => {'call'};

  @override
  Future<SkillResult> run(ParsedIntent intent) async {
    final query = (intent.args['query'] ?? '').toString().trim();
    if (query.isEmpty) return SkillResult.failed('Call who?');

    // A number spoken/typed directly, e.g. "call 555 0100".
    final digitsOnly = query.replaceAll(RegExp(r'[\s\-]'), '');
    if (RegExp(r'^\+?[0-9]{5,}$').hasMatch(digitsOnly)) {
      final ok = await _bridge.dialNumber(digitsOnly);
      return ok ? SkillResult.ok('Dialing $digitsOnly.') : SkillResult.failed("Couldn't open the dialer.");
    }

    final contact = await _bridge.findContact(query);
    if (contact == null) {
      return SkillResult.failed(
        'No contact matching "$query" — or contacts access isn\'t granted.',
      );
    }
    final ok = await _bridge.dialNumber(contact['number']!);
    return ok
        ? SkillResult.ok('Calling ${contact['name']}.')
        : SkillResult.failed("Couldn't open the dialer for ${contact['name']}.");
  }
}
