/// What a skill hands back to the worker loop. `spokenResponse` is fed to TTS.
class SkillResult {
  SkillResult.ok(this.spokenResponse) : success = true;
  SkillResult.failed(this.spokenResponse) : success = false;

  final bool success;
  final String spokenResponse;

  @override
  String toString() => 'SkillResult(${success ? 'ok' : 'failed'}: $spokenResponse)';
}
