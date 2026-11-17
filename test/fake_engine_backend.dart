// FakeEngineBackend — an in-memory fake of the native engine for testing
// the TrainingManager and UI without the native library. Training returns
// a steadily decreasing fake loss so the chart/stats logic can be exercised.
import 'package:tinytrainer_engine/tinytrainer_engine.dart';
import 'package:tiny_trainer/engine/engine_backend.dart';

class FakeEngineBackend implements EngineBackend {
  TrainConfig? createdConfig;
  String? corpusText;
  int step = 0;
  double loss = 5.0;
  int paramCountValue = 2400000;
  int vocabSizeValue = 0;
  bool failNextCreate = false;
  bool failNextLoad = false;
  final List<String> savedPaths = [];
  final List<String> loadedPaths = [];

  @override
  Future<bool> create(TrainConfig config) async {
    if (failNextCreate) {
      failNextCreate = false;
      return false;
    }
    createdConfig = config;
    step = 0;
    loss = 5.0;
    vocabSizeValue = 0;
    return true;
  }

  @override
  Future<bool> setCorpus(String text) async {
    if (text.trim().isEmpty) return false;
    corpusText = text;
    vocabSizeValue = 500;
    return true;
  }

  @override
  Future<List<double>> trainChunk(int steps) async {
    // Simulate real training latency so the manager's loop yields.
    await Future<void>.delayed(const Duration(milliseconds: 10));
    final out = <double>[];
    for (var i = 0; i < steps; i++) {
      loss = (loss - 0.05).clamp(0.5, 10.0);
      step++;
      out.add(loss);
    }
    return out;
  }

  @override
  Future<String> generate(
    String prompt, {
    int maxTokens = 64,
    double temperature = 0.8,
    int topK = 40,
    int seed = 0,
  }) async {
    if (prompt.isEmpty) return '';
    return '这是假生成的内容。';
  }

  @override
  Future<bool> saveBrain(String path) async {
    savedPaths.add(path);
    return true;
  }

  @override
  Future<bool> loadBrain(String path) async {
    if (failNextLoad) {
      failNextLoad = false;
      return false;
    }
    loadedPaths.add(path);
    step = 100;
    vocabSizeValue = 500;
    return true;
  }

  @override
  Future<void> setLr(double lr) async {}

  @override
  Future<void> setBatchSize(int batch) async {}

  @override
  Future<Map<String, dynamic>?> getInfo() async {
    if (createdConfig == null && loadedPaths.isEmpty) return null;
    return {
      'step': step,
      'paramCount': paramCountValue,
      'vocabSize': vocabSizeValue,
      'loss': loss,
      'corpusTokens': 1000,
    };
  }

  @override
  Future<void> dispose() async {}
}
