/// Structured output from the LLM. The LLM is prompted to return exactly this
/// shape as JSON — `skill` picks the handler, `args` is passed through to it.
class ParsedIntent {
  ParsedIntent({
    required this.skill,
    required this.action,
    this.args = const {},
    this.rationale,
    this.clarifyingQuestion,
  });

  /// e.g. "system", "app_launcher", "whatsapp".
  final String skill;

  /// e.g. "battery", "open", "send". Combined as "$skill.$action" for the
  /// irreversible-action check.
  final String action;

  final Map<String, dynamic> args;

  /// Short "why this action" line from the model (debugging / trust).
  final String? rationale;

  /// If set, the command was ambiguous — ask this instead of dispatching.
  final String? clarifyingQuestion;

  String get qualifiedName => '$skill.$action';

  bool get needsClarification =>
      clarifyingQuestion != null && clarifyingQuestion!.trim().isNotEmpty;

  factory ParsedIntent.fromJson(Map<String, dynamic> json) => ParsedIntent(
        skill: (json['skill'] ?? '').toString(),
        action: (json['action'] ?? '').toString(),
        args: (json['args'] as Map?)?.cast<String, dynamic>() ?? const {},
        rationale: json['rationale']?.toString(),
        clarifyingQuestion: json['clarifying_question']?.toString(),
      );

  Map<String, dynamic> toJson() => {
        'skill': skill,
        'action': action,
        'args': args,
        if (rationale != null) 'rationale': rationale,
        if (clarifyingQuestion != null) 'clarifying_question': clarifyingQuestion,
      };

  @override
  String toString() => 'ParsedIntent($qualifiedName, args: $args)';
}
