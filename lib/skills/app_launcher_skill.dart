import '../models/parsed_intent.dart';
import '../models/skill_result.dart';
import '../services/native_bridge.dart';
import '../utils/logger.dart';
import 'skill.dart';

/// Generic "open any app". No per-app hardcoding: the spoken app name is
/// resolved against the device's installed launcher entries at runtime, then
/// launched via intent.
class AppLauncherSkill extends Skill {
  AppLauncherSkill({NativeBridge? bridge}) : _bridge = bridge ?? NativeBridge.instance;

  final NativeBridge _bridge;

  @override
  String get name => 'app_launcher';

  @override
  String get usage => 'open an installed app. args: {"query": "<spoken app name>"}';

  @override
  Set<String> get actions => {'open'};

  @override
  Future<SkillResult> run(ParsedIntent intent) async {
    final query = (intent.args['query'] ?? '').toString().trim();
    if (query.isEmpty) return SkillResult.failed('Which app?');

    final apps = await _bridge.listLaunchableApps();
    final match = _bestMatch(query, apps);
    if (match == null) {
      return SkillResult.failed('No app called "$query" on this device.');
    }

    log.i('Launching ${match.label} (${match.package}) for "$query"');
    final ok = await _bridge.launchApp(match.package);
    return ok
        ? SkillResult.ok('Opening ${match.label}.')
        : SkillResult.failed("Couldn't open ${match.label}.");
  }

  /// Case-insensitive: exact label, then prefix, then substring, then a loose
  /// token overlap. Deliberately simple — good enough for a spoken name.
  InstalledApp? _bestMatch(String query, List<InstalledApp> apps) {
    final q = query.toLowerCase();
    InstalledApp? substring;
    InstalledApp? prefix;
    for (final app in apps) {
      final label = app.label.toLowerCase();
      if (label == q) return app;
      if (prefix == null && label.startsWith(q)) prefix = app;
      if (substring == null && label.contains(q)) substring = app;
    }
    if (prefix != null) return prefix;
    if (substring != null) return substring;

    final qTokens = q.split(RegExp(r'\s+')).toSet();
    for (final app in apps) {
      final labelTokens = app.label.toLowerCase().split(RegExp(r'\s+')).toSet();
      if (labelTokens.intersection(qTokens).isNotEmpty) return app;
    }
    return null;
  }
}
