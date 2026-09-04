import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:get/get.dart';
import 'package:llama_sdk/llama_sdk.dart';

import '../config/nova_config.dart';
import '../models/parsed_intent.dart';
import '../skills/skill_registry.dart';
import '../utils/logger.dart';
import 'model_downloader.dart';
import 'model_store.dart';

/// On-device intent parsing.
///
/// Primary path: Qwen2.5-Instruct GGUF via llama.cpp ([llama_sdk], runs in its
/// own isolate). The model isn't bundled — [ModelDownloader] fetches it on
/// first run; until it's ready (and any time it errors) Nova falls back to a
/// keyword parser so every core command still works.
class LlmService {
  LlmService({
    required this.registry,
    ModelStore? models,
    ModelDownloader? downloader,
  })  : _models = models ?? ModelStore(),
        _downloader = downloader ?? ModelDownloader();

  final SkillRegistry registry;
  final ModelStore _models;
  final ModelDownloader _downloader;

  Llama? _llama;
  bool _busy = false;

  final RxBool modelReady = false.obs;
  final RxString modelStatus = 'starting'.obs;

  ModelDownloader get downloader => _downloader;

  Future<void> init() async {
    // Already loaded — never re-download or reload the model. Restarting the
    // listening service must not touch this.
    if (modelReady.value) return;

    final plan = await _downloader.plan();
    final path = await _models.path(plan.file);

    if (await File(path).exists()) {
      await _load(path);
    } else {
      modelStatus.value = 'downloading LLM (first run)';
      log.i('LLM model absent — downloading in background; keyword parser active');
      unawaited(_downloadThenLoad());
    }
  }

  Future<void> _downloadThenLoad() async {
    final path = await _downloader.ensureLlmModel();
    if (path == null) {
      modelStatus.value = 'LLM download failed — using keyword parser';
      return;
    }
    await _load(path);
  }

  Future<void> _load(String path) async {
    try {
      modelStatus.value = 'loading LLM';
      _llama = Llama(LlamaController(
        modelPath: path,
        nCtx: NovaConfig.llmContextSize,
        nBatch: 512,
        greedy: true,
      ));
      modelReady.value = true;
      modelStatus.value = 'LLM ready';
      log.i('LlmService: model loaded from $path');
    } catch (e, s) {
      log.e('LlmService: model load failed', e, s);
      modelReady.value = false;
      modelStatus.value = 'LLM load failed — using keyword parser';
    }
  }

  /// Returns the structured intent for [transcript].
  Future<ParsedIntent> parse(String transcript) async {
    if (modelReady.value && _llama != null && !_busy) {
      _busy = true;
      try {
        final raw = await _generate(transcript);
        final intent = _parseModelJson(raw);
        if (intent != null) return intent;
        log.w('LLM output not parseable: $raw');
      } catch (e) {
        log.w('LLM generate failed ($e) — keyword fallback');
      } finally {
        _busy = false;
      }
    }
    return _keywordFallback(transcript);
  }

  Future<String> _generate(String transcript) async {
    final messages = <LlamaMessage>[
      SystemLlamaMessage(_systemPrompt()),
      UserLlamaMessage(transcript),
    ];
    final buf = StringBuffer();
    try {
      await for (final tok
          in _llama!.prompt(messages).timeout(const Duration(seconds: 25))) {
        buf.write(tok);
        if (buf.length > 600) break; // the JSON object is small
      }
    } on TimeoutException {
      log.w('LLM generation timed out');
    } finally {
      _llama?.stop();
    }
    return buf.toString();
  }

  String _systemPrompt() => '${NovaConfig.personalitySystemPrompt}\n\n'
      '${registry.promptCatalog()}\n'
      'Reply with ONLY a JSON object, no prose, with keys: '
      'skill (string), action (string), args (object), and optionally '
      'rationale (string) or clarifying_question (string). '
      'If the request is ambiguous, set clarifying_question and leave skill "none".';

  // Tolerant of text around the JSON.
  ParsedIntent? _parseModelJson(String raw) {
    final start = raw.indexOf('{');
    final end = raw.lastIndexOf('}');
    if (start < 0 || end <= start) return null;
    try {
      final map = jsonDecode(raw.substring(start, end + 1)) as Map<String, dynamic>;
      final intent = ParsedIntent.fromJson(map);
      if (intent.skill.isEmpty) return null;
      return intent;
    } catch (e) {
      log.w('JSON decode failed: $e');
      return null;
    }
  }

  // ── Keyword fallback ───────────────────────────────────────────────────
  // Covers every core command so Nova is useful with or without the LLM.
  ParsedIntent _keywordFallback(String transcript) {
    final t = transcript.toLowerCase().trim().replaceAll(RegExp(r'[.?!,]+$'), '');
    if (t.isEmpty) return _ask("I didn't catch that — say again?");

    if (RegExp(r"\b(what'?s the |whats the |what |current )?time\b").hasMatch(t) ||
        t == 'time') {
      return ParsedIntent(skill: 'clock', action: 'time', rationale: 'time check');
    }
    if (RegExp(r"\b(what'?s the |whats the |what |today'?s )?date\b").hasMatch(t) ||
        t.contains('what day is it') ||
        t.contains("what's the day")) {
      return ParsedIntent(skill: 'clock', action: 'date', rationale: 'date check');
    }
    if (t.contains('battery') || t.contains('charge') || t.contains('power level')) {
      return ParsedIntent(skill: 'system', action: 'battery', rationale: 'battery check');
    }
    if (t.contains('flashlight') || t.contains('torch')) {
      return ParsedIntent(
        skill: 'system',
        action: 'flashlight',
        args: {'on': !t.contains('off')},
        rationale: 'flashlight toggle',
      );
    }
    if (RegExp(r'\bvolume\b').hasMatch(t) ||
        t.contains('turn it up') ||
        t.contains('turn it down')) {
      final mute = t.contains('mute') || t.contains('silent');
      final down = t.contains('down') || t.contains('lower') || t.contains('quiet');
      return ParsedIntent(
        skill: 'system',
        action: 'volume',
        args: {'delta': mute ? 0 : (down ? -2 : 2)},
        rationale: 'volume change',
      );
    }

    const msgVerb = r'(?:message|whatsapp|text|tell|send(?: a)? message to)';
    final waFull = RegExp(
      '\\b$msgVerb\\s+([a-z]+(?:\\s+[a-z]+)?)\\s+'
      r'(?:on\s+whatsapp\s+)?(?:saying|that|:)\s+(.+)$',
    ).firstMatch(t);
    if (waFull != null) {
      return ParsedIntent(
        skill: 'whatsapp',
        action: 'send',
        args: {'contact': waFull.group(1)!.trim(), 'text': waFull.group(2)!.trim()},
        rationale: 'whatsapp message',
      );
    }
    final waName = RegExp('\\b$msgVerb\\s+([a-z]+)\\b').firstMatch(t);
    if (waName != null) {
      return _ask('What should I say to ${waName.group(1)!.trim()}?');
    }

    final call = RegExp(r'\b(?:call|dial|phone)\s+(.+)$').firstMatch(t);
    if (call != null) {
      // Strip trailing filler like "... from contact(s)".
      final who = call.group(1)!.trim().replaceFirst(RegExp(r'\s+from\s+contacts?$'), '');
      return ParsedIntent(
        skill: 'phone',
        action: 'call',
        args: {'query': who},
        rationale: 'call "$who"',
      );
    }

    final open =
        RegExp(r'\b(?:open|launch|start|go to|show me)\s+(?:the\s+)?(.+)$')
            .firstMatch(t);
    if (open != null) {
      final q = open.group(1)!.trim().replaceFirst(RegExp(r'\s+app$'), '');
      return ParsedIntent(
        skill: 'app_launcher',
        action: 'open',
        args: {'query': q},
        rationale: 'open an app',
      );
    }

    final note = RegExp(r'\b(?:note|remember|jot down)\b\s*(?:that|to)?\s*(.*)$')
        .firstMatch(t);
    if (note != null && (note.group(1) ?? '').isNotEmpty) {
      return ParsedIntent(
        skill: 'notes',
        action: 'add',
        args: {'text': note.group(1)!.trim()},
        rationale: 'note to self',
      );
    }
    if (t.contains('note') && (t.contains('read') || t.contains('what are'))) {
      return ParsedIntent(skill: 'notes', action: 'read', rationale: 'read notes');
    }

    return _ask(
      'Not sure. Try "open <app>", "message <name> saying <text>", '
      '"battery", "time", or "note <something>".',
    );
  }

  ParsedIntent _ask(String q) =>
      ParsedIntent(skill: 'none', action: 'none', clarifyingQuestion: q);

  Future<void> dispose() async {
    try {
      _llama?.stop();
      _llama?.reload();
    } catch (_) {}
    _llama = null;
    modelReady.value = false;
  }
}
