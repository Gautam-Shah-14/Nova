import 'dart:math';

import '../config/nova_config.dart';

/// Turns a skill's plain, functional line into Tony Stark's voice: cocky,
/// fast, technically smug, allergic to sincerity, secretly efficient. Original
/// lines written in that register — not lifted movie dialogue (the one
/// exception is the wake acknowledgement in [NovaConfig], which is a
/// deliberate, explicit quote by request).
///
/// Deliberately pattern-matched rather than LLM-generated — it works the
/// instant the app launches, not only once the (slow, sometimes-unloaded) LLM
/// is ready, and it never touches messages that were already hand-authored
/// (confirmations, clarifying questions, allow-list refusals) — clarity beats
/// a bit there, especially anywhere a wrong guess costs something.
///
/// Includes light roasting: repeating the same request gets called out, and
/// there's a low, unprompted chance of a jab on any ordinary response — rare
/// enough to stay "dry humor, not every line," per the brief.
class Personality {
  Personality._();

  static final Random _r = Random();
  static String? _lastKind;
  static int _repeatStreak = 0;

  static String stylize(String plain) {
    final result = _lineFor(plain);
    if (result == null) return plain; // hand-authored — leave it alone

    final (kind, options) = result;
    final repeating = kind == _lastKind;
    _repeatStreak = repeating ? _repeatStreak + 1 : 0;
    _lastKind = kind;

    var line = _pick(options);

    if (repeating && _repeatStreak >= 1 && _r.nextDouble() < 0.6) {
      line = '${_pick(_repeatRoasts)} $line';
    } else if (!repeating && _r.nextDouble() < 0.12) {
      line = '${_pick(_looseJabs)} $line';
    }

    return _withName(line);
  }

  /// Every recognised message shape and its Stark-voiced options. Returns
  /// null for anything unmatched — the "leave it alone" path in [stylize].
  static (String, List<String>)? _lineFor(String plain) {
    final open = RegExp(r'^Opening (.+)\.$').firstMatch(plain);
    if (open != null) return ('open', _openLines(open.group(1)!));

    final battery =
        RegExp(r'^Battery is at (\d+) percent(, charging)?\.$').firstMatch(plain);
    if (battery != null) {
      final pct = int.parse(battery.group(1)!);
      final charging = battery.group(2) != null;
      return ('battery', _batteryLines(pct, charging));
    }

    if (plain == 'Noted.') {
      return (
        'note',
        [
          'Noted.',
          "Got it. Try not to forget it yourself this time.",
          "Filed. You're welcome.",
          "Noted. Riveting stuff.",
        ]
      );
    }

    if (plain == 'Deleted.') {
      return ('delete', ['Deleted.', 'Gone. Like it never happened.', "Erased. Don't tell anyone."]);
    }

    final time = RegExp(r"^It's (\d{1,2}:\d{2} (?:AM|PM))\.$").firstMatch(plain);
    if (time != null) {
      final t = time.group(1)!;
      return ('time', ['$t.', "$t. Time's still doing its thing.", "$t — try to be productive."]);
    }

    final date = RegExp(
      r'^(Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday), .+\.$',
    ).firstMatch(plain);
    if (date != null) {
      return ('date', [plain, "$plain Don't say I never do anything for you."]);
    }

    final calling = RegExp(r'^Calling (.+)\.$').firstMatch(plain);
    if (calling != null) {
      final who = calling.group(1)!;
      return ('call', ['Calling $who.', 'Ringing $who up. Try to sound normal.', 'Patching you through to $who.']);
    }
    final dialing = RegExp(r'^Dialing (.+)\.$').firstMatch(plain);
    if (dialing != null) return ('dial', ['Dialing.', 'Connecting you now.']);

    final flashlight = RegExp(r'^Flashlight (on|off)\.$').firstMatch(plain);
    if (flashlight != null) {
      final on = flashlight.group(1) == 'on';
      return (
        'flashlight',
        on
            ? ['Flashlight on.', 'Let there be light.', "There. Now you can see how messy this is."]
            : ['Flashlight off.', 'Lights out.', 'Back to darkness. Your call.']
      );
    }

    if (plain == 'Volume up.') return ('volume', ['Volume up.', 'Turning it up. Neighbors, beware.']);
    if (plain == 'Volume down.') return ('volume', ['Volume down.', 'Easing off, before someone complains.']);
    if (plain == 'Muted.') return ('volume', ['Muted.', "Silenced. Peace, finally."]);

    final sentTo = RegExp(r'^Sent to (.+)\.$').firstMatch(plain);
    if (sentTo != null) {
      return ('whatsapp', ['Sent to ${sentTo.group(1)}.', 'Message away. Try not to regret it.']);
    }

    if (plain.startsWith("Couldn't") || plain.startsWith('Something went wrong')) {
      return (
        'error',
        [
          plain,
          '$plain Not my finest moment.',
          '$plain — even I have off days.',
          '$plain Blame the hardware, not the genius.',
        ]
      );
    }

    if (plain.startsWith('Not sure.')) {
      return (
        'unclear',
        [
          plain,
          "Come again? Use your words. $plain",
          "That one didn't parse. $plain",
        ]
      );
    }

    return null;
  }

  static List<String> _openLines(String app) => [
        'Opening $app.',
        '$app, coming right up.',
        'On it — $app.',
        'Sure. $app it is.',
        '$app. Groundbreaking request, truly.',
        "Opening $app. Try to contain your excitement.",
      ];

  static List<String> _batteryLines(int pct, bool charging) {
    if (pct <= 15) {
      return [
        '$pct percent. You might want a cable.',
        '$pct percent — living dangerously, are we?',
        '$pct percent. Bold strategy, waiting this long.',
      ];
    }
    if (charging) {
      return ['$pct percent, charging.', '$pct percent and topping up. Look at you, being responsible.'];
    }
    return ['$pct percent.', "$pct percent. You're fine. Relax.", '$pct percent. Could be worse.'];
  }

  static const _repeatRoasts = [
    "Heard you the first time.",
    "You literally just asked that.",
    "Again? I'm good, not deaf.",
    "Persistent. I respect it, barely.",
  ];

  static const _looseJabs = [
    "Genius move.",
    "Groundbreaking.",
    "Try to keep up.",
    "Look at you, giving orders.",
    "Fine, I'll bite.",
  ];

  static String _pick(List<String> options) => options[_r.nextInt(options.length)];

  /// Occasionally prefixes the configured name — "not every line", per the
  /// design doc. No-op while [NovaConfig.userName] is unset.
  static String _withName(String line) {
    if (NovaConfig.userName.isEmpty) return line;
    if (_r.nextDouble() > 0.25) return line;
    return '${NovaConfig.userName}, ${line[0].toLowerCase()}${line.substring(1)}';
  }
}
