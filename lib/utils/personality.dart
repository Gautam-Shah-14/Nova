import 'dart:math';

import '../config/nova_config.dart';

/// Turns a skill's plain, functional line into something that sounds like the
/// design doc's Nova: sharp, dry, economical, occasionally uses your name.
/// Deliberately pattern-matched rather than LLM-generated — it works the
/// instant the app launches, not only once the (slow, sometimes-unloaded) LLM
/// is ready, and it never touches messages that were already hand-authored
/// (confirmations, clarifying questions, allow-list refusals).
class Personality {
  Personality._();

  static final Random _r = Random();

  static String stylize(String plain) {
    final open = RegExp(r'^Opening (.+)\.$').firstMatch(plain);
    if (open != null) return _withName(_pick(_openLines(open.group(1)!)));

    final battery =
        RegExp(r'^Battery is at (\d+) percent(, charging)?\.$').firstMatch(plain);
    if (battery != null) {
      final pct = int.parse(battery.group(1)!);
      final charging = battery.group(2) != null;
      return _withName(_pick(_batteryLines(pct, charging)));
    }

    if (plain == 'Noted.') {
      return _pick(['Noted.', 'Got it — filed away.', "Noted. Won't forget."]);
    }

    if (plain == 'Deleted.') return _pick(['Deleted.', 'Gone.', 'Done — deleted.']);

    final time = RegExp(r"^It's (\d{1,2}:\d{2} (?:AM|PM))\.$").firstMatch(plain);
    if (time != null) return _pick(['${time.group(1)}.', 'It\'s ${time.group(1)} — time flies.']);

    final calling = RegExp(r'^Calling (.+)\.$').firstMatch(plain);
    if (calling != null) {
      final who = calling.group(1)!;
      return _withName(_pick(['Calling $who.', 'Ringing $who up.', 'Patching you through to $who.']));
    }
    final dialing = RegExp(r'^Dialing (.+)\.$').firstMatch(plain);
    if (dialing != null) return _pick(['Dialing.', 'Connecting you now.']);

    final flashlight = RegExp(r'^Flashlight (on|off)\.$').firstMatch(plain);
    if (flashlight != null) {
      final on = flashlight.group(1) == 'on';
      return _pick(on
          ? ['Flashlight on.', "Let there be light.", 'Lighting the way.']
          : ['Flashlight off.', 'Lights out.']);
    }

    if (plain == 'Volume up.') return _pick(['Volume up.', 'Turning it up.']);
    if (plain == 'Volume down.') return _pick(['Volume down.', 'Easing off.']);
    if (plain == 'Muted.') return _pick(['Muted.', 'Silenced.']);

    final sentTo = RegExp(r'^Sent to (.+)\.$').firstMatch(plain);
    if (sentTo != null) return _pick(['Sent to ${sentTo.group(1)}.', 'Message away.']);

    if (plain.startsWith("Couldn't") || plain.startsWith('Something went wrong')) {
      return _pick([plain, '$plain Not my finest moment.', '$plain — try again?']);
    }

    // Clarifying questions, confirmation prompts, allow-list refusals, and
    // anything else unrecognised: leave verbatim. Clarity beats wit there.
    return plain;
  }

  static List<String> _openLines(String app) => [
        'Opening $app.',
        '$app, coming right up.',
        'On it — $app.',
        'Sure. $app it is.',
      ];

  static List<String> _batteryLines(int pct, bool charging) {
    if (pct <= 15) {
      return ['$pct percent. You might want a cable.', '$pct percent — living dangerously.'];
    }
    if (charging) return ['$pct percent, charging.', '$pct percent and topping up.'];
    return ['$pct percent.', "$pct percent. You're fine."];
  }

  static String _pick(List<String> options) => options[_r.nextInt(options.length)];

  /// Occasionally prefixes the configured name — "not every line", per the
  /// design doc. No-op while [NovaConfig.userName] is unset.
  static String _withName(String line) {
    if (NovaConfig.userName.isEmpty) return line;
    if (_r.nextDouble() > 0.25) return line;
    return '${NovaConfig.userName}, ${line[0].toLowerCase()}${line.substring(1)}';
  }
}
