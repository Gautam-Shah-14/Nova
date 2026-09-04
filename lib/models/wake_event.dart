/// A wake-word hit. In plugin-STT mode [command] carries the recognised command
/// text directly (SpeechRecognizer gives us words, not audio). [audioPath] is
/// used only by the future whisper path, where the service captures a WAV.
class WakeEvent {
  WakeEvent({required this.at, this.command, this.audioPath});

  final DateTime at;
  final String? command;
  final String? audioPath;

  bool get hasCommand => command != null && command!.trim().isNotEmpty;
  bool get hasAudio => audioPath != null && audioPath!.isNotEmpty;
}
