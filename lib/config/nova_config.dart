/// Static configuration for Nova. No secrets here — this file is meant to be
/// read and tweaked by hand.
library;

class NovaConfig {
  NovaConfig._();

  /// Native <-> Dart channels. Must match `NovaChannels.kt`.
  static const String bridgeChannel = 'com.tokenburners.nova/bridge';
  static const String eventsChannel = 'com.tokenburners.nova/events';
  static const String sttChannel = 'com.tokenburners.nova/stt';
  static const String llmChannel = 'com.tokenburners.nova/llm';
  static const String a11yChannel = 'com.tokenburners.nova/a11y';

  /// Model files, expected under `<appSupportDir>/models/`.
  static const String whisperModelFile = 'whisper/ggml-base.en.bin';
  static const String llmPrimaryFile = 'llm/qwen2.5-3b-instruct-q4_k_m.gguf';
  static const String llmFallbackFile = 'llm/qwen2.5-1.5b-instruct-q4_k_m.gguf';

  /// First-run download source for the primary LLM weight (~1.9 GB, no gate).
  static const String llmDownloadUrl =
      'https://huggingface.co/Qwen/Qwen2.5-3B-Instruct-GGUF/resolve/main/qwen2.5-3b-instruct-q4_k_m.gguf?download=true';

  /// Lighter weight for low-RAM devices (~1.1 GB).
  static const String llmFallbackDownloadUrl =
      'https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/qwen2.5-1.5b-instruct-q4_k_m.gguf?download=true';

  /// Below this much total RAM, use the 1B fallback LLM.
  static const int llmFallbackRamThresholdMb = 4096;

  /// LLM context window when loading the GGUF model.
  static const int llmContextSize = 2048;

  /// Words that count as "yes" in the spoken confirmation step.
  static const Set<String> affirmations = <String>{
    'yes', 'yeah', 'yep', 'confirm', 'confirmed', 'do it', 'go ahead', 'sure', 'ok', 'okay',
  };

  /// How long a pending confirmation stays open for the follow-up wake.
  static const Duration confirmationWindow = Duration(seconds: 20);

  /// Set this to have Nova address you by name occasionally (see
  /// `Personality`). Empty = never uses a name.
  static const String userName = '';

  /// Wake phrase Nova listens for, and the spoken variants that count as a
  /// match (SpeechRecognizer mishears short names a lot). All lowercase.
  /// "Tony" is primary — shorter/more distinct than "Nova" for the
  /// recognizer, and pairs with the Stark-style wake acknowledgement below.
  static const String wakePhrase = 'Tony';
  static const List<String> wakeAliases = <String>[
    'tony', 'toni', 'tonee', 'toney', 'tone e', 'sony',
    'nova', 'no va', 'nldova', 'jarvis',
  ];

  /// Spoken the moment the wake word is heard, before Nova processes the
  /// command — confirms it's listening, Stark-style.
  static const String wakeAcknowledgement = 'I am Iron Man.';

  /// Cap on pending tasks. Past this, Nova says "hold on, catching up" instead
  /// of silently dropping a command. See [NovaConfig] usage in the queue.
  static const int maxQueueDepth = 5;

  /// Auto-drop to `sleeping` after this long with the screen off.
  static const Duration idleSleepTimeout = Duration(minutes: 2);

  /// Hard allow-list for WhatsApp sends. Enforced at the dispatcher, entirely
  /// independent of whatever contact name the LLM produces — a misheard name
  /// can never resolve to someone outside this list.
  static const List<String> whatsappAllowList = <String>[
    // 'Alex Doe',
    // 'Mum',
  ];

  /// Actions the reasoning engine treats as irreversible — these always need
  /// confirmation before the skill runs.
  static const Set<String> irreversibleIntents = <String>{
    'whatsapp.send',
    'gmail.send',
    'notes.delete',
    'file.delete',
  };

  /// Shared verbatim with the desktop build so both feel like one assistant.
  static const String personalitySystemPrompt = '''
You are Nova, the user's personal AI companion. Tone: sharp, witty, quietly
confident, economical with words — you respect the user's time and intelligence.
Dry humor over enthusiasm. You call the user by name occasionally, not every
line. You never pad responses with filler or apologize excessively. When a
command is ambiguous, you ask ONE crisp clarifying question instead of guessing.

Before acting, briefly reason: what is the user actually asking for, which skill
matches, and is this action reversible or not. For irreversible actions (sending
a message/email, deleting something), state what you're about to do and wait for
confirmation before executing — don't skip this step even if the command sounded
clear.

You always output your action as JSON matching the provided skill schema — no
prose mixed into that output, aside from the stated reasoning/confirmation step
where applicable.
''';
}
