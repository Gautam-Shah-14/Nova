import 'parsed_intent.dart';

/// Output of `reasoning_engine.dart` — sits between intent parsing and dispatch.
class ReasoningResult {
  ReasoningResult({
    required this.intent,
    required this.rationale,
    required this.reversible,
    required this.needsConfirmation,
    this.confirmationPrompt,
    this.blockedReason,
  });

  /// The intent under review (unchanged — reasoning only annotates).
  final ParsedIntent intent;

  /// Short stated "why this action".
  final String rationale;

  /// Reversible: open app, check battery, read something.
  /// Irreversible: send message/email, delete something.
  final bool reversible;

  /// Irreversible actions require a lightweight confirmation before executing.
  final bool needsConfirmation;

  /// What Nova states/speaks before committing, e.g.
  /// "Send 'running late' to Alex on WhatsApp?".
  final String? confirmationPrompt;

  /// Set when reasoning refuses outright (e.g. WhatsApp contact not on the
  /// allow-list) — the dispatcher never sees it.
  final String? blockedReason;

  bool get blocked => blockedReason != null;
}
