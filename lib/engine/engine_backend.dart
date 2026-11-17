// EngineBackend — the minimal backend surface the TrainingManager needs.
// [EngineWorker] (lib/engine/engine_worker.dart) is the real implementation
// (a background isolate owning the native engine); tests inject a fake.
// Kept in its own file so the worker and the manager can both import it
// without a circular dependency.
import 'package:tinytrainer_engine/tinytrainer_engine.dart';

abstract class EngineBackend {
  Future<bool> create(TrainConfig config);
  Future<bool> setCorpus(String text);
  Future<List<double>> trainChunk(int steps);
  Future<String> generate(
    String prompt, {
    int maxTokens,
    double temperature,
    int topK,
    int seed,
  });
  Future<bool> saveBrain(String path);
  Future<bool> loadBrain(String path);
  Future<void> setLr(double lr);
  Future<void> setBatchSize(int batch);
  Future<Map<String, dynamic>?> getInfo();
  Future<void> dispose();
}
