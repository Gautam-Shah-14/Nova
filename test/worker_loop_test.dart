import 'package:flutter_test/flutter_test.dart';
import 'package:nova/config/nova_config.dart';
import 'package:nova/models/parsed_intent.dart';
import 'package:nova/services/llm_service.dart';
import 'package:nova/services/reasoning_engine.dart';
import 'package:nova/skills/skill_registry.dart';
import 'package:nova/utils/personality.dart';

ParsedIntent _intent(String skill, String action, [Map<String, dynamic> args = const {}]) =>
    ParsedIntent(skill: skill, action: action, args: args);

void main() {
  group('LlmService keyword fallback', () {
    final llm = LlmService(registry: SkillRegistry());

    test('routes "what\'s my battery" to system.battery', () async {
      final intent = await llm.parse("what's my battery at");
      expect(intent.skill, 'system');
      expect(intent.action, 'battery');
    });

    test('routes "open Spotify" to app_launcher with the query', () async {
      final intent = await llm.parse('open spotify');
      expect(intent.qualifiedName, 'app_launcher.open');
      expect(intent.args['query'], 'spotify');
    });

    test('routes "note that ..." to notes.add', () async {
      final intent = await llm.parse('note that the wifi password is hunter2');
      expect(intent.qualifiedName, 'notes.add');
      expect(intent.args['text'], contains('hunter2'));
    });

    test('unknown command asks one clarifying question', () async {
      final intent = await llm.parse('do a barrel roll');
      expect(intent.needsClarification, isTrue);
    });

    test('routes "open WhatsApp" to app_launcher', () async {
      final intent = await llm.parse('open WhatsApp');
      expect(intent.qualifiedName, 'app_launcher.open');
      expect(intent.args['query'], 'whatsapp');
    });

    test('routes "launch the camera app" to app_launcher, stripping filler', () async {
      final intent = await llm.parse('launch the camera app');
      expect(intent.qualifiedName, 'app_launcher.open');
      expect(intent.args['query'], 'camera');
    });

    test('routes a WhatsApp message with body to whatsapp.send', () async {
      final intent =
          await llm.parse('message Alex on WhatsApp saying running ten late');
      expect(intent.qualifiedName, 'whatsapp.send');
      expect(intent.args['contact'], 'alex');
      expect(intent.args['text'], contains('running'));
    });

    test('a WhatsApp message with no body asks what to say', () async {
      final intent = await llm.parse('text mum');
      expect(intent.needsClarification, isTrue);
    });

    test('routes "what\'s the time" to clock.time', () async {
      final intent = await llm.parse("what's the time");
      expect(intent.qualifiedName, 'clock.time');
    });

    test('routes "what\'s the date" to clock.date', () async {
      final intent = await llm.parse("what's the date");
      expect(intent.qualifiedName, 'clock.date');
    });

    test('routes "flash on" and "flash off" to system.flashlight', () async {
      final on = await llm.parse('flash on');
      expect(on.qualifiedName, 'system.flashlight');
      expect(on.args['on'], isTrue);

      final off = await llm.parse('flash off');
      expect(off.qualifiedName, 'system.flashlight');
      expect(off.args['on'], isFalse);
    });

    test('routes "call <name> from contact" to phone.call, stripping filler', () async {
      final intent = await llm.parse('call Dhruv Brahmbhatt PU from contact');
      expect(intent.qualifiedName, 'phone.call');
      expect(intent.args['query'], 'dhruv brahmbhatt pu');
    });

    test('routes a spoken phone number to phone.call', () async {
      final intent = await llm.parse('dial 555 0100');
      expect(intent.qualifiedName, 'phone.call');
      expect(intent.args['query'], '555 0100');
    });
  });

  group('Personality', () {
    test('stylizes a recognised "Opening X." line without changing the app name', () {
      final styled = Personality.stylize('Opening Instagram.');
      expect(styled, contains('Instagram'));
    });

    test('passes unrecognised lines through verbatim', () {
      const clarifying = 'What should I say to Alex?';
      expect(Personality.stylize(clarifying), clarifying);
    });

    test('roasts a repeated request of the same kind', () {
      Personality.stylize('Opening Instagram.'); // first — no repeat streak yet
      final second = Personality.stylize('Opening Instagram.');
      // Roast is probabilistic (60%), but over many tries at least one must land.
      final anyRoasted = List.generate(40, (_) {
            Personality.stylize('Opening Instagram.');
            return Personality.stylize('Opening Instagram.');
          }).any((s) =>
              s.contains('Heard you') ||
              s.contains('literally just') ||
              s.contains("I'm good, not deaf") ||
              s.contains('Persistent'));
      expect(second, contains('Instagram')); // still a valid app-open line
      expect(anyRoasted, isTrue);
    });
  });

  group('ReasoningEngine', () {
    final engine = ReasoningEngine();

    test('reversible action passes straight through', () {
      final result = engine.review(
        ParsedIntent(skill: 'system', action: 'battery'),
      );
      expect(result.reversible, isTrue);
      expect(result.needsConfirmation, isFalse);
      expect(result.blocked, isFalse);
    });

    test('irreversible action requires confirmation', () {
      final result = engine.review(
        ParsedIntent(
          skill: 'notes',
          action: 'delete',
          args: {'target': 'last note'},
        ),
      );
      expect(result.reversible, isFalse);
      expect(result.needsConfirmation, isTrue);
      expect(result.confirmationPrompt, isNotEmpty);
    });

    test('WhatsApp send to a non-allow-listed contact is blocked', () {
      final result = engine.review(
        ParsedIntent(
          skill: 'whatsapp',
          action: 'send',
          args: {'contact': 'Some Stranger', 'text': 'hi'},
        ),
      );
      expect(result.blocked, isTrue);
      expect(result.blockedReason, contains('allow-list'));
    });

    test('irreversible intent set stays in sync with qualified names', () {
      expect(NovaConfig.irreversibleIntents, contains('whatsapp.send'));
      expect(NovaConfig.irreversibleIntents, contains('notes.delete'));
    });
  });

  group('SkillRegistry', () {
    final registry = SkillRegistry();

    test('resolves the generic app-control and whatsapp skills', () {
      expect(registry.resolve(_intent('app_control', 'tap'))?.name, 'app_control');
      expect(registry.resolve(_intent('whatsapp', 'send'))?.name, 'whatsapp');
    });

    test('returns null for an unknown skill', () {
      expect(registry.resolve(_intent('teleport', 'now')), isNull);
    });

    test('prompt catalog lists every installed skill', () {
      final catalog = registry.promptCatalog();
      for (final skill in registry.all) {
        expect(catalog, contains(skill.name));
      }
    });
  });
}
