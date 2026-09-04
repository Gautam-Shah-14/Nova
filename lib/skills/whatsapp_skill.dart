import '../config/nova_config.dart';
import '../models/parsed_intent.dart';
import '../models/skill_result.dart';
import '../services/accessibility_service.dart';
import '../services/native_bridge.dart';
import 'skill.dart';

/// Thin config on top of the generic Accessibility driver: a hard allow-list of
/// contacts. The allow-list is *also* enforced in `reasoning_engine.dart` before
/// this runs — this second check is defence in depth, independent of the LLM.
///
/// `send` is listed in [NovaConfig.irreversibleIntents], so the reasoning
/// engine's confirmation step always runs first.
class WhatsAppSkill extends Skill {
  WhatsAppSkill({AccessibilityService? a11y, NativeBridge? bridge})
      : a11y = a11y ?? AccessibilityService(),
        _bridge = bridge ?? NativeBridge.instance;

  final AccessibilityService a11y;
  final NativeBridge _bridge;

  static const _package = 'com.whatsapp';

  @override
  String get name => 'whatsapp';

  @override
  String get usage =>
      'send a WhatsApp message to an allow-listed contact. '
      'args: {"contact": "<name>", "text": "<message>"}';

  @override
  Set<String> get actions => {'send'};

  @override
  Future<SkillResult> run(ParsedIntent intent) async {
    final contact = (intent.args['contact'] ?? '').toString().trim();
    final text = (intent.args['text'] ?? '').toString().trim();
    if (contact.isEmpty || text.isEmpty) {
      return SkillResult.failed('Need a contact and a message.');
    }

    // Defence in depth — the LLM's output never gets a say here.
    final allowed = NovaConfig.whatsappAllowList
        .any((n) => n.toLowerCase() == contact.toLowerCase());
    if (!allowed) {
      return SkillResult.failed('"$contact" isn\'t on the WhatsApp allow-list.');
    }

    if (!await a11y.isConnected()) {
      return SkillResult.failed(
          'Enable Nova\'s accessibility service in Android Settings first.');
    }

    if (!await _bridge.launchApp(_package)) {
      return SkillResult.failed('WhatsApp isn\'t installed.');
    }
    await _settle();

    // Search → open the chat → type → send. Best-effort UI driving; labels come
    // from WhatsApp's content descriptions and shift over time.
    if (!(await a11y.tapText('Search')).ok) {
      return SkillResult.failed('Couldn\'t open WhatsApp search.');
    }
    await _settle();
    await a11y.typeInto(text: contact);
    await _settle();
    if (!(await a11y.tapText(contact)).ok) {
      return SkillResult.failed('Couldn\'t find the chat with $contact.');
    }
    await _settle();

    await a11y.typeInto(target: 'Message', text: text);
    await _settle(short: true);
    final sent = await a11y.tapText('Send');
    return sent.ok
        ? SkillResult.ok('Sent to $contact.')
        : SkillResult.failed('Typed it, but couldn\'t hit send.');
  }

  Future<void> _settle({bool short = false}) =>
      Future<void>.delayed(Duration(milliseconds: short ? 350 : 900));
}
