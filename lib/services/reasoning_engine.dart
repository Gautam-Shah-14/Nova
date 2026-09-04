import '../config/nova_config.dart';
import '../models/parsed_intent.dart';
import '../models/reasoning_result.dart';
import '../utils/logger.dart';

/// Sits between intent parsing and dispatch. Not personality flavour — it
/// actually gates risky actions:
///  - states a short rationale for the chosen action
///  - classifies reversible vs irreversible
///  - irreversible actions get a confirmation prompt before the skill runs
///  - a misheard WhatsApp contact is caught here, before the allow-list check
class ReasoningEngine {
  ReasoningResult review(ParsedIntent intent) {
    final irreversible =
        NovaConfig.irreversibleIntents.contains(intent.qualifiedName);

    final rationale = intent.rationale?.trim().isNotEmpty == true
        ? intent.rationale!.trim()
        : _inferRationale(intent);

    // WhatsApp: catch a bad contact name before it reaches the dispatcher's
    // hard allow-list, so the failure message is about the name, not a silent
    // no-op.
    if (intent.qualifiedName == 'whatsapp.send') {
      final contact = (intent.args['contact'] ?? '').toString().trim();
      if (contact.isEmpty) {
        return _blocked(intent, rationale, 'No contact given for the message.');
      }
      if (!_onAllowList(contact)) {
        return _blocked(
          intent,
          rationale,
          '"$contact" isn\'t on your WhatsApp allow-list — not sending.',
        );
      }
    }

    if (irreversible) {
      return ReasoningResult(
        intent: intent,
        rationale: rationale,
        reversible: false,
        needsConfirmation: true,
        confirmationPrompt: _confirmationFor(intent),
      );
    }

    return ReasoningResult(
      intent: intent,
      rationale: rationale,
      reversible: true,
      needsConfirmation: false,
    );
  }

  bool _onAllowList(String contact) {
    final c = contact.toLowerCase();
    return NovaConfig.whatsappAllowList
        .any((name) => name.toLowerCase() == c);
  }

  ReasoningResult _blocked(ParsedIntent intent, String rationale, String reason) {
    log.w('reasoning blocked ${intent.qualifiedName}: $reason');
    return ReasoningResult(
      intent: intent,
      rationale: rationale,
      reversible: false,
      needsConfirmation: false,
      blockedReason: reason,
    );
  }

  String _confirmationFor(ParsedIntent intent) {
    switch (intent.qualifiedName) {
      case 'whatsapp.send':
        return 'Send "${intent.args['text']}" to ${intent.args['contact']} on WhatsApp?';
      case 'gmail.send':
        return 'Send this email to ${intent.args['to']}?';
      case 'notes.delete':
      case 'file.delete':
        return 'Delete ${intent.args['target'] ?? 'that'} — sure?';
      default:
        return 'Go ahead with ${intent.qualifiedName}?';
    }
  }

  String _inferRationale(ParsedIntent intent) =>
      'Best match for the request is ${intent.qualifiedName}.';
}
