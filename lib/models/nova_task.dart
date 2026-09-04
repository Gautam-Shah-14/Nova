/// One unit of work on the FIFO queue. Created the moment the wake word fires,
/// then carried through STT -> LLM -> reasoning -> dispatch -> skill -> TTS.
class NovaTask {
  NovaTask({
    required this.id,
    required this.createdAt,
    this.audioPath,
    this.transcript,
  });

  final String id;
  final DateTime createdAt;

  /// Captured utterance to run STT on. Null for text-originated tasks.
  final String? audioPath;

  /// Null until STT fills it in. May be set at creation for text tasks.
  String? transcript;

  factory NovaTask.now({String? audioPath, String? transcript}) => NovaTask(
        id: DateTime.now().microsecondsSinceEpoch.toRadixString(16),
        createdAt: DateTime.now(),
        audioPath: audioPath,
        transcript: transcript,
      );

  @override
  String toString() => 'NovaTask($id, "${transcript ?? audioPath ?? '<empty>'}")';
}
