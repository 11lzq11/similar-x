// Train tab: corpus management, hyper-parameters, start/pause/stop, and
// the live LOSS chart + stats.
import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:tinytrainer_engine/tinytrainer_engine.dart';

import '../l10n/strings.dart';
import '../models.dart';
import '../services/training_manager.dart';
import 'loss_chart.dart';

class TrainPage extends StatefulWidget {
  final TrainingManager manager;

  const TrainPage({super.key, required this.manager});

  @override
  State<TrainPage> createState() => _TrainPageState();
}

class _TrainPageState extends State<TrainPage> {
  late final TextEditingController _lrController;
  late final TextEditingController _batchController;
  late final TextEditingController _blockController;
  late final TextEditingController _layerController;
  late final TextEditingController _embdController;
  late final TextEditingController _headController;
  late final TextEditingController _vocabController;
  late final TextEditingController _warmupController;
  late final TextEditingController _wdController;

  @override
  void initState() {
    super.initState();
    final c = widget.manager.currentConfig;
    _lrController = TextEditingController(text: c.lr.toString());
    _batchController = TextEditingController(text: c.batchSize.toString());
    _blockController = TextEditingController(text: c.blockSize.toString());
    _layerController = TextEditingController(text: c.nLayer.toString());
    _embdController = TextEditingController(text: c.nEmbd.toString());
    _headController = TextEditingController(text: c.nHead.toString());
    _vocabController = TextEditingController(text: c.vocabSize.toString());
    _warmupController = TextEditingController(text: c.warmupSteps.toString());
    _wdController = TextEditingController(text: c.weightDecay.toString());
  }

  @override
  void dispose() {
    _lrController.dispose();
    _batchController.dispose();
    _blockController.dispose();
    _layerController.dispose();
    _embdController.dispose();
    _headController.dispose();
    _vocabController.dispose();
    _warmupController.dispose();
    _wdController.dispose();
    super.dispose();
  }

  TrainConfig _readConfig() {
    final c = widget.manager.currentConfig;
    return TrainConfig(
      lr: double.tryParse(_lrController.text.trim()) ?? c.lr,
      batchSize: int.tryParse(_batchController.text.trim()) ?? c.batchSize,
      blockSize: int.tryParse(_blockController.text.trim()) ?? c.blockSize,
      nLayer: int.tryParse(_layerController.text.trim()) ?? c.nLayer,
      nEmbd: int.tryParse(_embdController.text.trim()) ?? c.nEmbd,
      nHead: int.tryParse(_headController.text.trim()) ?? c.nHead,
      vocabSize: int.tryParse(_vocabController.text.trim()) ?? c.vocabSize,
      warmupSteps: int.tryParse(_warmupController.text.trim()) ?? c.warmupSteps,
      weightDecay: double.tryParse(_wdController.text.trim()) ?? c.weightDecay,
      seed: c.seed,
    );
  }

  Future<void> _startTraining() async {
    final s = Strings.of(context);
    final config = _readConfig();
    if (!config.isValid) {
      _showSnack(s.msgInvalidParams);
      return;
    }
    // Changing the structure drops the current brain — confirm first.
    if (widget.manager.hasBrain &&
        !widget.manager.currentConfig.structureEquals(config)) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(s.msgStructureChange),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('确定'),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }
    final ready = await widget.manager.prepareForTraining(config);
    if (!ready) {
      final msg = widget.manager.takeMessage();
      if (msg != null) _showSnack(msg);
      return;
    }
    widget.manager.requestStart();
    _showSnack(s.msgTrainingStarted);
  }

  void _showSnack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _importCorpusFile() async {
    final s = Strings.of(context);
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['txt'],
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;
    final file = result.files.first;
    final bytes = file.bytes;
    if (bytes == null) {
      _showSnack(s.msgImportFailed);
      return;
    }
    final text = String.fromCharCodes(bytes);
    final name = file.name.replaceAll(RegExp(r'\.txt$', caseSensitive: false), '');
    final ok = await widget.manager.addCorpus(name, text);
    _showSnack(ok ? s.msgCorpusAdded : s.msgCorpusEmpty);
  }

  Future<void> _pasteCorpus() async {
    final s = Strings.of(context);
    final nameController = TextEditingController();
    final textController = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(s.addCorpusPaste),
        content: SizedBox(
          width: 400,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameController,
                decoration: InputDecoration(hintText: s.corpusNameHint),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: textController,
                decoration: InputDecoration(hintText: s.corpusTextHint),
                maxLines: 8,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (ok == true) {
      final added = await widget.manager.addCorpus(
        nameController.text,
        textController.text,
      );
      _showSnack(added ? s.msgCorpusAdded : s.msgCorpusEmpty);
    }
    nameController.dispose();
    textController.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    return AnimatedBuilder(
      animation: widget.manager,
      builder: (context, _) {
        final manager = widget.manager;
        final state = manager.trainState;
        final stats = manager.stats;
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // Live stats + chart.
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        _stat(s.step, '${stats.step}'),
                        _stat(
                          s.loss,
                          stats.loss.isNaN ? '—' : stats.loss.toStringAsFixed(4),
                        ),
                        _stat(
                          s.tokensPerSec,
                          stats.tokensPerSec.toStringAsFixed(1),
                        ),
                        _stat(s.elapsed, _formatElapsed(stats.elapsedMs)),
                      ],
                    ),
                    const SizedBox(height: 8),
                    LossChart(points: manager.lossHistory),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: FilledButton(
                    onPressed: state == TrainState.idle ? _startTraining : null,
                    child: Text(s.startTraining),
                  ),
                ),
                const SizedBox(width: 8),
                if (state == TrainState.running)
                  Expanded(
                    child: OutlinedButton(
                      onPressed: manager.requestPause,
                      child: Text(s.pause),
                    ),
                  ),
                if (state == TrainState.paused)
                  Expanded(
                    child: OutlinedButton(
                      onPressed: manager.requestResume,
                      child: Text(s.resume),
                    ),
                  ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton(
                    onPressed: state == TrainState.idle
                        ? null
                        : () async {
                            await manager.requestStop();
                            final msg = manager.takeMessage();
                            if (msg != null && context.mounted) {
                              _showSnack(msg);
                            }
                          },
                    child: Text(s.stop),
                  ),
                ),
              ],
            ),
            if (!manager.hasBrain && state == TrainState.idle) ...[
              const SizedBox(height: 8),
              Text(s.noBrainYet, style: const TextStyle(color: Colors.grey)),
            ],
            const SizedBox(height: 16),
            Text(s.corpusSection,
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            if (manager.corpora.isEmpty)
              Text(s.noCorpus, style: const TextStyle(color: Colors.grey)),
            for (final item in manager.corpora)
              CheckboxListTile(
                title: Text(item.name),
                subtitle: Text('${(item.sizeBytes / 1024).toStringAsFixed(1)} KB'),
                value: item.active,
                onChanged: (v) =>
                    manager.setCorpusActive(item.name, v ?? false),
                secondary: IconButton(
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => manager.deleteCorpus(item.name),
                ),
              ),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _pasteCorpus,
                    icon: const Icon(Icons.text_fields),
                    label: Text(s.addCorpusPaste),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _importCorpusFile,
                    icon: const Icon(Icons.upload_file),
                    label: Text(s.addCorpusFile),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Text(s.hyperSection,
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            _numField(s.lr, _lrController),
            _numField(s.batchSize, _batchController),
            _numField(s.blockSize, _blockController),
            _numField(s.nLayer, _layerController),
            _numField(s.nEmbd, _embdController),
            _numField(s.nHead, _headController),
            _numField(s.vocabSize, _vocabController),
            _numField(s.warmup, _warmupController),
            _numField(s.weightDecay, _wdController),
            const SizedBox(height: 24),
          ],
        );
      },
    );
  }

  Widget _stat(String label, String value) {
    return Expanded(
      child: Column(
        children: [
          Text(label, style: const TextStyle(color: Colors.grey, fontSize: 12)),
          const SizedBox(height: 2),
          Text(value,
              style:
                  const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
        ],
      ),
    );
  }

  Widget _numField(String label, TextEditingController controller) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(width: 110, child: Text(label)),
          Expanded(
            child: TextField(
              controller: controller,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                isDense: true,
                contentPadding:
                    EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _formatElapsed(int ms) {
    final s = ms ~/ 1000;
    final h = s ~/ 3600;
    final m = (s % 3600) ~/ 60;
    final sec = s % 60;
    if (h > 0) return '${h}h ${m}m';
    if (m > 0) return '${m}m ${sec}s';
    return '${sec}s';
  }
}
