// Brain tab: brain info, export/import, new brain, load base brain,
// language switch.
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';

import '../l10n/strings.dart';
import '../services/training_manager.dart';

class BrainPage extends StatelessWidget {
  final TrainingManager manager;

  const BrainPage({super.key, required this.manager});

  Future<void> _exportBrain(BuildContext context) async {
    final s = Strings.of(context);
    if (!manager.hasBrain) {
      _snack(context, s.msgNoBrain);
      return;
    }
    final dir = await getApplicationDocumentsDirectory();
    final tmp = File('${dir.path}/export-tmp.brain');
    final ok = await manager.saveBrainFile(tmp.path);
    if (!context.mounted) return;
    if (!ok) {
      _snack(context, s.msgSaveFailed);
      return;
    }
    final bytes = await tmp.readAsBytes();
    await tmp.delete();
    final name = 'brain-${manager.brainInfo.step}.brain';
    final outPath = await FilePicker.platform.saveFile(
      dialogTitle: s.exportBrain,
      fileName: name,
      bytes: bytes,
    );
    if (!context.mounted) return;
    if (outPath != null) {
      _snack(context, s.msgBrainExported);
    }
  }

  Future<void> _importBrain(BuildContext context) async {
    final s = Strings.of(context);
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['brain'],
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;
    final file = result.files.first;
    final bytes = file.bytes;
    if (bytes == null) {
      if (!context.mounted) return;
      _snack(context, s.msgImportFailed);
      return;
    }
    final dir = await getApplicationDocumentsDirectory();
    final tmp = File('${dir.path}/import-tmp.brain');
    await tmp.writeAsBytes(bytes);
    final ok = await manager.loadBrainFile(tmp.path);
    await tmp.delete();
    if (!context.mounted) return;
    _snack(context, ok ? s.msgBrainImported : s.msgLoadFailed);
  }

  Future<void> _newBrain(BuildContext context) async {
    final s = Strings.of(context);
    final ok = await manager.createNewBrain(manager.currentConfig);
    if (!context.mounted) return;
    if (ok) {
      _snack(context, s.msgBrainCreated);
    } else {
      // Show the manager's real reason (validation / engine not ready /
      // creation failed) instead of always blaming the hyper-parameters.
      _snack(context, manager.takeMessage() ?? s.msgInvalidParams);
    }
  }

  Future<void> _loadBaseBrain(BuildContext context) async {
    final s = Strings.of(context);
    final status = await manager.loadBaseBrain();
    if (!context.mounted) return;
    switch (status) {
      case 'OK':
        _snack(context, s.msgBaseBrainLoaded);
      case 'PLACEHOLDER':
        _snack(context, s.msgBaseBrainPlaceholder);
      default:
        _snack(context, s.msgLoadFailed);
    }
  }

  void _snack(BuildContext context, String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    return AnimatedBuilder(
      animation: manager,
      builder: (context, _) {
        final info = manager.brainInfo;
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(s.brainInfo, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  children: [
                    _infoRow(s.arch, info.archString()),
                    _infoRow(
                      s.params,
                      info.paramCount == 0
                          ? '—'
                          : info.paramCount.toString(),
                    ),
                    _infoRow(
                      s.vocab,
                      info.vocabSize == 0 ? '—' : info.vocabSize.toString(),
                    ),
                    _infoRow(s.step, '${info.step}'),
                    _infoRow(
                      s.loss,
                      info.loss.isNaN ? '—' : info.loss.toStringAsFixed(4),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: () => _exportBrain(context),
              icon: const Icon(Icons.upload),
              label: Text(s.exportBrain),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: () => _importBrain(context),
              icon: const Icon(Icons.download),
              label: Text(s.importBrain),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: () => _newBrain(context),
              icon: const Icon(Icons.psychology),
              label: Text(s.newBrain),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: () => _loadBaseBrain(context),
              icon: const Icon(Icons.school),
              label: Text(s.loadBaseBrain),
            ),
            const SizedBox(height: 24),
            Text(s.language, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            SegmentedButton<AppLocale>(
              segments: const [
                ButtonSegment(value: AppLocale.zh, label: Text('中文')),
                ButtonSegment(value: AppLocale.en, label: Text('English')),
              ],
              selected: {s.locale},
              onSelectionChanged: (sel) {
                final locale = sel.first;
                StringsScope.setLocale(context, locale);
                TrainingManager.saveLocale(locale);
              },
            ),
            const SizedBox(height: 16),
            Text(s.aboutPerf, style: const TextStyle(color: Colors.grey)),
            const SizedBox(height: 24),
          ],
        );
      },
    );
  }

  Widget _infoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(width: 90, child: Text(label, style: const TextStyle(color: Colors.grey))),
          Expanded(
            child: Text(value, style: const TextStyle(fontWeight: FontWeight.w500)),
          ),
        ],
      ),
    );
  }
}
