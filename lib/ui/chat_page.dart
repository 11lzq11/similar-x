// Chat tab: prompt + temperature/Top-K + generate. Works during training
// too (the worker isolate serialises generate between train chunks).
import 'package:material_ui/material_ui.dart';

import '../l10n/strings.dart';
import '../services/training_manager.dart';

class ChatPage extends StatefulWidget {
  final TrainingManager manager;

  const ChatPage({super.key, required this.manager});

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final _promptController = TextEditingController();
  double _temperature = 0.8;
  double _topK = 40;
  double _maxTokens = 64;

  @override
  void dispose() {
    _promptController.dispose();
    super.dispose();
  }

  Future<void> _generate() async {
    final s = Strings.of(context);
    if (_promptController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(s.msgEnterPrompt)));
      return;
    }
    await widget.manager.generate(
      _promptController.text,
      maxTokens: _maxTokens.toInt(),
      temperature: _temperature,
      topK: _topK.toInt(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = Strings.of(context);
    return AnimatedBuilder(
      animation: widget.manager,
      builder: (context, _) {
        final manager = widget.manager;
        return Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (!manager.hasBrain)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(s.noBrainChat,
                      style: const TextStyle(color: Colors.grey)),
                ),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _promptController,
                      decoration: InputDecoration(
                        hintText: s.promptHint,
                        border: const OutlineInputBorder(),
                      ),
                      maxLines: 2,
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: manager.generating ? null : _generate,
                    child: Text(
                      manager.generating ? s.generating : s.generate,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              _sliderRow(
                s.temperature,
                _temperature.toStringAsFixed(2),
                _temperature,
                0.1,
                2.0,
                (v) => setState(() => _temperature = v),
              ),
              _sliderRow(
                s.topK,
                _topK.toInt().toString(),
                _topK,
                0,
                200,
                (v) => setState(() => _topK = v),
              ),
              _sliderRow(
                s.maxTokens,
                _maxTokens.toInt().toString(),
                _maxTokens,
                16,
                500,
                (v) => setState(() => _maxTokens = v),
              ),
              const SizedBox(height: 16),
              Expanded(
                child: SingleChildScrollView(
                  child: SelectableText(
                    manager.lastGeneration.isEmpty
                        ? ''
                        : manager.lastGeneration,
                    style: const TextStyle(fontSize: 16, height: 1.6),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _sliderRow(
    String label,
    String value,
    double current,
    double min,
    double max,
    ValueChanged<double> onChanged,
  ) {
    return Row(
      children: [
        SizedBox(width: 80, child: Text(label)),
        Expanded(
          child: Slider(
            value: current,
            min: min,
            max: max,
            divisions: ((max - min) / (min < 1 ? 0.05 : 1)).round().clamp(1, 200),
            onChanged: onChanged,
          ),
        ),
        SizedBox(width: 48, child: Text(value, textAlign: TextAlign.right)),
      ],
    );
  }
}
