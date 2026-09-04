/// The single state source the docs describe — one enum drives both render
/// targets (foreground-service notification icon + floating overlay dot).
enum NovaStatus {
  /// Queue empty, listening for the wake word.
  available,

  /// Queue non-empty. Stays here across a whole backlog, not per task.
  working,

  /// Listening paused — screen-off idle timeout or a manual pause.
  sleeping;

  /// Wire value sent to the native side (`setStatus`).
  String get wire => switch (this) {
        NovaStatus.available => 'available',
        NovaStatus.working => 'working',
        NovaStatus.sleeping => 'sleeping',
      };

  /// Colour of the generated dot when no custom icon is baked in.
  int get colorValue => switch (this) {
        NovaStatus.available => 0xFF2E7D32, // green
        NovaStatus.working => 0xFFF5B301, // yellow
        NovaStatus.sleeping => 0xFFE53935, // red
      };
}
