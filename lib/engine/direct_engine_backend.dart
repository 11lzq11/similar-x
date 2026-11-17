// DirectEngineBackend — runs the native engine on the MAIN isolate.
//
// Fallback when the background worker isolate cannot be used (spawn fails,
// or the worker's create fails on the device). Training chunks block the UI
// briefly, but the app works. The interface is identical to EngineWorker
// so TrainingManager can swap backends transparently.
//
// Why this exists: on some Android devices the worker isolate's FFI calls
// fail (create returns false / the isolate cannot resolve the native
// symbols), while the exact same C engine works fine on the main isolate.
// Rather than leaving the user with a dead "创建大脑失败", fall back.
import 'package:tinytrainer_engine/tinytrainer_engine.dart';

import 'engine_backend.dart';

class DirectEngineBackend implements EngineBackend {
  TinyTrainerEngine? _engine;

  /// The last native error, if any (for diagnostics).
  String? lastError;

  @override
  Future<bool> create(TrainConfig config) async {
    try {
      _engine?.dispose();
      final created = TinyTrainerEngine.create(config);
      if (created == null) {
        lastError = 'native tg_create returned null';
        return false;
      }
      _engine = created;
      lastError = null;
      return true;
    } catch (e) {
      lastError = e.toString();
      return false;
    }
  }

  @override
  Future<bool> setCorpus(String text) async {
    final e = _engine;
    if (e == null) return false;
    try {
      return e.setCorpus(text);
    } catch (err) {
      lastError = err.toString();
      return false;
    }
  }

  @override
  Future<List<double>> trainChunk(int steps) async {
    final e = _engine;
    if (e == null) return const [];
    try {
      return e.trainSteps(steps);
    } catch (err) {
      lastError = err.toString();
      return const [];
    }
  }

  @override
  Future<String> generate(
    String prompt, {
    int maxTokens = 64,
    double temperature = 0.8,
    int topK = 40,
    int seed = 0,
  }) async {
    final e = _engine;
    if (e == null) return '';
    try {
      return e.generate(
        prompt,
        maxTokens: maxTokens,
        temperature: temperature,
        topK: topK,
        seed: seed,
      );
    } catch (err) {
      lastError = err.toString();
      return '';
    }
  }

  @override
  Future<bool> saveBrain(String path) async {
    final e = _engine;
    if (e == null) return false;
    try {
      return e.saveBrain(path);
    } catch (err) {
      lastError = err.toString();
      return false;
    }
  }

  @override
  Future<bool> loadBrain(String path) async {
    try {
      _engine?.dispose();
      final loaded = TinyTrainerEngine.loadBrain(path);
      if (loaded == null) {
        lastError = 'native tg_load_brain returned null';
        return false;
      }
      _engine = loaded;
      lastError = null;
      return true;
    } catch (e) {
      lastError = e.toString();
      return false;
    }
  }

  @override
  Future<void> setLr(double lr) async {
    _engine?.setLr(lr);
  }

  @override
  Future<void> setBatchSize(int batch) async {
    _engine?.setBatchSize(batch);
  }

  @override
  Future<Map<String, dynamic>?> getInfo() async {
    final e = _engine;
    if (e == null) return null;
    try {
      return {
        'ok': true,
        'step': e.step,
        'paramCount': e.paramCount,
        'vocabSize': e.vocabSize,
        'loss': e.loss,
        'corpusTokens': e.corpusTokens,
      };
    } catch (err) {
      lastError = err.toString();
      return null;
    }
  }

  @override
  Future<void> dispose() async {
    _engine?.dispose();
    _engine = null;
  }
}
