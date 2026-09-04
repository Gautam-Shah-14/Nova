import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../controllers/queue_controller.dart';
import '../controllers/service_controller.dart';
import '../services/llm_service.dart';
import '../services/model_downloader.dart';
import '../services/tts_service.dart';

/// Status console. Nova is meant to be screenless, but this is how you see
/// permissions, whether speech recognition/the LLM loaded, the model
/// download, and drive a command by hand.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  final _cmd = TextEditingController();
  final _service = Get.find<ServiceController>();
  final _queue = Get.find<QueueController>();
  final _tts = Get.find<TtsService>();
  final _llm = Get.find<LlmService>();

  bool _startingListen = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _cmd.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _service.refreshStatus();
  }

  void _snack(String m) => ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(m), duration: const Duration(seconds: 3)));

  Future<void> _testVoice() async {
    final ok = await _tts.speak('Nova here. Voice output is working.');
    _snack(ok ? 'Sent to the speech engine.' : 'TTS refused it. ${_tts.lastError}');
  }

  Future<void> _startListening() async {
    setState(() => _startingListen = true);
    final err = await _service.enableListening();
    if (!mounted) return;
    setState(() => _startingListen = false);
    _snack(err ?? 'Listening. Say "Nova, open contacts".');
  }

  void _run([String? preset]) {
    final text = preset ?? _cmd.text;
    if (text.trim().isEmpty) return;
    _queue.enqueue(text: text.trim());
    _cmd.clear();
    FocusScope.of(context).unfocus();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Nova · status'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => _service.refreshStatus(),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _statusCard(),
          const SizedBox(height: 12),
          _downloadCard(),
          const SizedBox(height: 16),

          Obx(() => FilledButton.icon(
                onPressed: _startingListen || _service.listening.value
                    ? null
                    : _startListening,
                icon: _startingListen
                    ? const SizedBox(
                        width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : Icon(_service.listening.value ? Icons.hearing : Icons.hearing_disabled),
                label: Text(_startingListen
                    ? 'Starting…'
                    : _service.listening.value
                        ? 'Listening'
                        : 'Start listening'),
              )),
          const SizedBox(height: 4),
          Text(
            'Say "Nova, <command>" once this is on. Restart it here if the OS '
            'ever reclaims the mic.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 12),

          Row(
            children: [
              Expanded(
                child: FilledButton.tonalIcon(
                  onPressed: _testVoice,
                  icon: const Icon(Icons.volume_up),
                  label: const Text('Test voice'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Obx(() => FilledButton.tonalIcon(
                      onPressed: _service.listening.value
                          ? () {
                              _service.simulateWake();
                              _snack('Speak your command now');
                            }
                          : null,
                      icon: const Icon(Icons.mic),
                      label: const Text('Talk'),
                    )),
              ),
            ],
          ),
          const Divider(height: 32),

          Text('Type a command', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          TextField(
            controller: _cmd,
            textInputAction: TextInputAction.go,
            onSubmitted: (_) => _run(),
            decoration: InputDecoration(
              hintText: 'e.g. open contacts',
              border: const OutlineInputBorder(),
              suffixIcon:
                  IconButton(icon: const Icon(Icons.send), onPressed: () => _run()),
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final c in const [
                "what's the time",
                'battery',
                'open contacts',
                'open whatsapp',
                'flashlight on',
              ])
                ActionChip(label: Text(c), onPressed: () => _run(c)),
            ],
          ),
          const Divider(height: 32),

          Text('Last exchange', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Obx(() => _bubble('You', _queue.lastHeard.value)),
          const SizedBox(height: 6),
          Obx(() => _bubble('Nova', _queue.lastResponse.value, accent: true)),
        ],
      ),
    );
  }

  Widget _statusCard() => Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Obx(() => Column(
                children: [
                  _row('Microphone', _service.micGranted.value),
                  _row('Notifications', _service.notificationsGranted.value),
                  _row('Display over apps', _service.overlayGranted.value),
                  _row('Voice output (TTS)',
                      _service.bootstrapped.value && _tts.ready),
                  _row('Speech recognition', _service.speechRecognitionReady.value),
                  _row('Wake listening', _service.listening.value),
                  _row('Accessibility service',
                      _service.accessibilityConnected.value),
                  _row('AI model (LLM)', _llm.modelReady.value),
                ],
              )),
        ),
      );

  Widget _downloadCard() => Obx(() {
        final d = _llm.downloader;
        final running = d.state.value == DownloadState.running;
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('LLM: ${_llm.modelStatus.value}',
                    style: Theme.of(context).textTheme.bodyMedium),
                if (running) ...[
                  const SizedBox(height: 8),
                  LinearProgressIndicator(
                      value: d.progress.value > 0 ? d.progress.value : null),
                  const SizedBox(height: 4),
                  Text(d.detail.value,
                      style: Theme.of(context).textTheme.bodySmall),
                ],
                if (d.state.value == DownloadState.failed)
                  Text('Download failed: ${d.detail.value}',
                      style: const TextStyle(color: Colors.redAccent)),
              ],
            ),
          ),
        );
      });

  Widget _row(String label, bool ok) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          children: [
            Icon(ok ? Icons.check_circle : Icons.cancel,
                color: ok ? Colors.green : Colors.redAccent, size: 20),
            const SizedBox(width: 10),
            Expanded(child: Text(label)),
          ],
        ),
      );

  Widget _bubble(String who, String text, {bool accent = false}) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: accent ? scheme.primaryContainer : scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(who, style: Theme.of(context).textTheme.labelSmall),
          const SizedBox(height: 2),
          Text(text.isEmpty ? '—' : text,
              style: Theme.of(context).textTheme.bodyLarge),
        ],
      ),
    );
  }
}
