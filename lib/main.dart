import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

import 'models/call_target.dart';
import 'services/campaign_runner.dart';
import 'services/root_audio.dart';
import 'services/telephony_service.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const CallerBotApp());
}

class CallerBotApp extends StatelessWidget {
  const CallerBotApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'CallerBot',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _numbersController = TextEditingController();
  String? _audioPath; // null => use bundled asset
  int _maxAttempts = 3;
  int _ringSeconds = 30;
  CampaignRunner? _runner;

  final AudioPlayer _preview = AudioPlayer();
  bool _previewing = false;

  @override
  void dispose() {
    _numbersController.dispose();
    _preview.dispose();
    _runner?.dispose();
    super.dispose();
  }

  Future<bool> _ensureReady() async {
    final phone = await Permission.phone.request();
    if (!phone.isGranted) {
      _snack('Phone permission is required to place calls.');
      return false;
    }
    return true;
  }

  Source _buildSource() {
    if (_audioPath != null) return DeviceFileSource(_audioPath!);
    return AssetSource('audio/message.mp3');
  }

  Future<void> _pickAudio() async {
    final result = await FilePicker.platform.pickFiles(type: FileType.audio);
    if (result != null && result.files.single.path != null) {
      setState(() => _audioPath = result.files.single.path);
    }
  }

  /// Plays the currently-selected message through the phone locally so the user
  /// can confirm the file is valid and audible before starting a campaign.
  Future<void> _previewMessage() async {
    if (_previewing) {
      await _preview.stop();
      setState(() => _previewing = false);
      return;
    }
    if (_audioPath != null && !await File(_audioPath!).exists()) {
      _snack('That audio file no longer exists — pick it again.');
      return;
    }
    try {
      _preview.onPlayerComplete.first.then((_) {
        if (mounted) setState(() => _previewing = false);
      });
      // Reset to a clean state first so a previously-wedged player can't fail.
      await _preview.release();
      await _preview.play(_buildSource());
      setState(() => _previewing = true);
    } catch (e) {
      _snack('Could not play this message: $e');
    }
  }

  Future<void> _start() async {
    final numbers = _numbersController.text
        .split(RegExp(r'[\n,]'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty);
    if (numbers.isEmpty) {
      _snack('Add at least one number.');
      return;
    }
    if (!await _ensureReady()) return;

    final runner = CampaignRunner(
      audioSource: _buildSource(),
      maxAttempts: _maxAttempts,
      ringTimeout: Duration(seconds: _ringSeconds),
    )..loadNumbers(numbers);

    setState(() => _runner = runner);
    await runner.start();
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _runRootDiagnostics() async {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
        content: Row(
          children: [
            CircularProgressIndicator(),
            SizedBox(width: 16),
            Expanded(child: Text('Running root probe…\nApprove the Magisk prompt.')),
          ],
        ),
      ),
    );

    RootResult result;
    try {
      result = await RootAudio.diagnostics();
    } catch (e) {
      result = RootResult(-1, 'Failed to run: $e');
    }
    if (!mounted) return;
    Navigator.of(context).pop(); // dismiss the spinner

    final text = result.output.trim().isEmpty
        ? 'No output (exit ${result.exitCode}). Root (su) may have been denied.'
        : result.output;

    await showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Root audio diagnostics'),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: SelectableText(
              text,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: text));
              if (mounted) _snack('Copied — paste it back to share.');
            },
            child: const Text('Copy'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('CallerBot'),
        actions: [
          IconButton(
            tooltip: 'Root audio diagnostics',
            icon: const Icon(Icons.bug_report),
            onPressed: _runRootDiagnostics,
          ),
        ],
      ),
      body: _runner == null ? _buildSetup() : _buildRunning(_runner!),
    );
  }

  Widget _buildSetup() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('Phone numbers',
              style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          const Text('One per line, or comma-separated',
              style: TextStyle(color: Colors.grey, fontSize: 12)),
          const SizedBox(height: 8),
          TextField(
            controller: _numbersController,
            keyboardType: TextInputType.multiline,
            maxLines: 8,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              hintText: '+15551234567\n+15559876543',
            ),
          ),
          const SizedBox(height: 20),
          Card(
            child: ListTile(
              leading: const Icon(Icons.audiotrack),
              title: Text(_audioPath == null
                  ? 'Bundled message (assets/audio/message.mp3)'
                  : _audioPath!.split(RegExp(r'[\\/]')).last),
              subtitle: const Text('Message played on the call (tap ▶ to test)'),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: _previewing ? 'Stop' : 'Preview',
                    icon: Icon(_previewing ? Icons.stop : Icons.play_arrow),
                    onPressed: _previewMessage,
                  ),
                  TextButton(
                    onPressed: _pickAudio,
                    child: const Text('Choose'),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          _stepperRow('Ring attempts per person', _maxAttempts, 1, 5,
              (v) => setState(() => _maxAttempts = v)),
          _stepperRow('Ring timeout (seconds)', _ringSeconds, 10, 60,
              (v) => setState(() => _ringSeconds = v), step: 5),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: _start,
            icon: const Icon(Icons.play_arrow),
            style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16)),
            label: const Text('Start calling'),
          ),
        ],
      ),
    );
  }

  Widget _stepperRow(
      String label, int value, int min, int max, ValueChanged<int> onChanged,
      {int step = 1}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(child: Text(label)),
          IconButton(
            icon: const Icon(Icons.remove_circle_outline),
            onPressed:
                value > min ? () => onChanged(value - step) : null,
          ),
          SizedBox(
              width: 32,
              child: Text('$value', textAlign: TextAlign.center)),
          IconButton(
            icon: const Icon(Icons.add_circle_outline),
            onPressed:
                value < max ? () => onChanged(value + step) : null,
          ),
        ],
      ),
    );
  }

  Widget _buildRunning(CampaignRunner runner) {
    return ChangeNotifierProvider.value(
      value: runner,
      child: Consumer<CampaignRunner>(
        builder: (context, r, _) {
          return Column(
            children: [
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                color: Theme.of(context).colorScheme.primaryContainer,
                child: Text(
                  r.statusMessage ?? 'Preparing…',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              Expanded(
                child: ListView.separated(
                  itemCount: r.targets.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, i) {
                    final t = r.targets[i];
                    final isCurrent = i == r.currentIndex && r.isRunning;
                    return ListTile(
                      leading: _statusIcon(t.status, isCurrent),
                      title: Text(t.number),
                      subtitle: Text(
                          '${t.statusLabel} · attempts ${t.attemptsMade}'),
                    );
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    if (r.isRunning)
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: r.cancel,
                          icon: const Icon(Icons.stop),
                          label: const Text('Stop'),
                        ),
                      )
                    else
                      Expanded(
                        child: FilledButton(
                          onPressed: () => setState(() => _runner = null),
                          child: const Text('Done'),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _statusIcon(TargetStatus status, bool isCurrent) {
    if (isCurrent) {
      return const SizedBox(
        width: 24,
        height: 24,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }
    return switch (status) {
      TargetStatus.delivered =>
        const Icon(Icons.check_circle, color: Colors.green),
      TargetStatus.noAnswer =>
        const Icon(Icons.phone_missed, color: Colors.orange),
      TargetStatus.failed => const Icon(Icons.error, color: Colors.red),
      _ => const Icon(Icons.schedule, color: Colors.grey),
    };
  }
}
