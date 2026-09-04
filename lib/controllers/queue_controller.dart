import 'dart:collection';

import 'package:get/get.dart';

import '../config/nova_config.dart';
import '../models/nova_status.dart';
import '../models/nova_task.dart';
import '../models/reasoning_result.dart';
import '../services/dispatcher.dart';
import '../services/llm_service.dart';
import '../services/reasoning_engine.dart';
import '../services/tts_service.dart';
import '../utils/logger.dart';
import 'status_controller.dart';

/// The FIFO queue + single worker loop from the design doc. Each wake-word hit
/// pushes a task; the loop drains one at a time:
///   (Vosk already gave us text) -> LLM -> reasoning -> dispatch -> skill -> TTS
/// The status icon reflects the whole queue, not the current task — one
/// continuous "working" signal across a backlog.
class QueueController extends GetxController {
  QueueController({
    required this.llm,
    required this.reasoning,
    required this.dispatcher,
    required this.tts,
    required this.statusController,
  });

  final LlmService llm;
  final ReasoningEngine reasoning;
  final Dispatcher dispatcher;
  final TtsService tts;
  final StatusController statusController;

  final Queue<NovaTask> _pending = Queue<NovaTask>();
  final RxInt depth = 0.obs;
  bool _draining = false;

  /// Surfaced for the debug screen — last command understood, last line spoken.
  final RxString lastHeard = ''.obs;
  final RxString lastResponse = ''.obs;

  /// An irreversible action that stated its confirmation prompt and is now
  /// waiting for the next utterance to be "yes"/"no". Cleared on answer or
  /// timeout ([NovaConfig.confirmationWindow]).
  ReasoningResult? _awaitingConfirmation;
  DateTime _confirmationDeadline = DateTime.fromMillisecondsSinceEpoch(0);

  /// Enqueue a recognised command (Vosk already turned speech into text).
  void enqueue({required String text}) {
    final t = text.trim();
    if (t.isEmpty) return;
    if (_pending.length >= NovaConfig.maxQueueDepth) {
      log.w('queue full (${_pending.length}) — dropping newest');
      _say('Hold on, catching up.');
      return;
    }
    final task = NovaTask.now(transcript: t);
    _pending.add(task);
    depth.value = _pending.length;
    log.i('enqueued $task (depth ${_pending.length})');
    _drain();
  }

  Future<void> _drain() async {
    if (_draining) return;
    _draining = true;
    await statusController.working();

    try {
      while (_pending.isNotEmpty) {
        final task = _pending.removeFirst();
        depth.value = _pending.length;
        await _runTask(task);
      }
    } finally {
      _draining = false;
      // Only fall back to available if we're not asleep for another reason.
      if (statusController.value == NovaStatus.working) {
        await statusController.available();
      }
    }
  }

  Future<void> _runTask(NovaTask task) async {
    try {
      final transcript = (task.transcript ?? '').trim();
      log.i('task ${task.id} transcript: "$transcript"');
      if (transcript.isNotEmpty) lastHeard.value = transcript;

      // If Nova just asked for confirmation, this utterance is the answer —
      // not a new command. Checked before the LLM so a bare "yes" isn't parsed
      // as an intent.
      if (_confirmationPending) {
        await _resolveConfirmation(transcript);
        return;
      }
      _awaitingConfirmation = null; // stale window — drop it

      // 2. LLM -> structured intent
      final intent = await llm.parse(transcript);
      if (intent.needsClarification) {
        await _say(intent.clarifyingQuestion!);
        return;
      }

      // 3. Reasoning — rationale, reversibility, confirmation, allow-list
      final reviewed = reasoning.review(intent);
      if (reviewed.blocked) {
        await _say(reviewed.blockedReason!);
        return;
      }
      if (reviewed.needsConfirmation) {
        // State what's about to happen and hold for the next utterance. The
        // design doc's alternative — a fixed pause-and-proceed window — would
        // slot in here instead.
        _awaitingConfirmation = reviewed;
        _confirmationDeadline = DateTime.now().add(NovaConfig.confirmationWindow);
        await _say('${reviewed.confirmationPrompt ?? 'Confirm?'} Say yes or no.');
        return;
      }

      // 4-6. Dispatch -> skill -> speak
      await _dispatchAndSpeak(reviewed);
    } catch (e, s) {
      log.e('task ${task.id} failed', e, s);
      await _say('Something went wrong with that one.');
    }
  }

  /// Speak a line and remember it for the debug screen.
  Future<void> _say(String line) async {
    lastResponse.value = line;
    await tts.speak(line);
  }

  bool get _confirmationPending =>
      _awaitingConfirmation != null &&
      DateTime.now().isBefore(_confirmationDeadline);

  Future<void> _resolveConfirmation(String answer) async {
    final held = _awaitingConfirmation;
    _awaitingConfirmation = null;
    if (held == null) return;

    final normalized = answer.toLowerCase().trim();
    final yes = NovaConfig.affirmations.any(normalized.contains);
    if (!yes) {
      await _say('Cancelled.');
      log.i('confirmation declined for ${held.intent.qualifiedName} ("$answer")');
      return;
    }
    log.i('confirmation granted for ${held.intent.qualifiedName}');
    await _dispatchAndSpeak(held);
  }

  Future<void> _dispatchAndSpeak(ReasoningResult reviewed) async {
    final result = await dispatcher.dispatch(reviewed);
    if (result.spokenResponse.isNotEmpty) {
      await _say(result.spokenResponse);
    }
  }
}
