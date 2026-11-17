// EngineWorker — runs the native engine on a dedicated background isolate.
//
// Why: the C engine's trainSteps/generate calls are blocking (they run the
// full forward/backward pass). Calling them on the main isolate would freeze
// the UI for seconds per chunk. The worker isolate owns the
// TinyTrainerEngine (native pointers cannot cross isolates) and processes
// commands strictly one at a time, so a generate can never race a weight
// update — no snapshot dance is needed (unlike the native Android app,
// where the training loop and generation share one handle).
//
// Protocol: the main isolate sends a Map command {'type', 'id', ...} and
// awaits a Map response {'id', ...}. Commands are processed FIFO, so a
// generate sent between two trainChunk calls runs before the next chunk.
import 'dart:async';
import 'dart:isolate';

import 'package:tinytrainer_engine/tinytrainer_engine.dart';

import 'engine_backend.dart';

/// The worker entry point (top-level so it can be spawned in an isolate).
void _engineWorkerMain(SendPort mainSendPort) {
  final receivePort = ReceivePort();
  mainSendPort.send(receivePort.sendPort);

  TinyTrainerEngine? engine;

  receivePort.listen((dynamic message) {
    final cmd = message as Map<String, dynamic>;
    final type = cmd['type'] as String;
    final id = cmd['id'] as int;
    try {
      switch (type) {
        case 'create': {
          engine?.dispose();
          final config = TrainConfig.fromJson(
            Map<String, dynamic>.from(cmd['config'] as Map),
          );
          final created = TinyTrainerEngine.create(config);
          if (created == null) {
            mainSendPort.send({'id': id, 'ok': false});
          } else {
            engine = created;
            mainSendPort.send({'id': id, 'ok': true});
          }
        }
        case 'setCorpus': {
          final e = engine;
          final ok = e != null && e.setCorpus(cmd['text'] as String);
          mainSendPort.send({'id': id, 'ok': ok});
        }
        case 'trainChunk': {
          final e = engine;
          if (e == null) {
            mainSendPort.send({'id': id, 'ok': false, 'losses': <double>[]});
          } else {
            final losses = e.trainSteps(cmd['steps'] as int);
            mainSendPort.send({'id': id, 'ok': true, 'losses': losses});
          }
        }
        case 'generate': {
          final e = engine;
          if (e == null) {
            mainSendPort.send({'id': id, 'ok': false, 'text': ''});
          } else {
            final text = e.generate(
              cmd['prompt'] as String,
              maxTokens: cmd['maxTokens'] as int,
              temperature: (cmd['temperature'] as num).toDouble(),
              topK: cmd['topK'] as int,
              seed: cmd['seed'] as int,
            );
            mainSendPort.send({'id': id, 'ok': true, 'text': text});
          }
        }
        case 'saveBrain': {
          final e = engine;
          final ok = e != null && e.saveBrain(cmd['path'] as String);
          mainSendPort.send({'id': id, 'ok': ok});
        }
        case 'loadBrain': {
          engine?.dispose();
          final loaded = TinyTrainerEngine.loadBrain(cmd['path'] as String);
          if (loaded == null) {
            mainSendPort.send({'id': id, 'ok': false});
          } else {
            engine = loaded;
            mainSendPort.send({'id': id, 'ok': true});
          }
        }
        case 'setLr': {
          engine?.setLr((cmd['lr'] as num).toDouble());
          mainSendPort.send({'id': id, 'ok': true});
        }
        case 'setBatchSize': {
          engine?.setBatchSize(cmd['batch'] as int);
          mainSendPort.send({'id': id, 'ok': true});
        }
        case 'getInfo': {
          final e = engine;
          if (e == null) {
            mainSendPort.send({'id': id, 'ok': false});
          } else {
            mainSendPort.send({
              'id': id,
              'ok': true,
              'step': e.step,
              'paramCount': e.paramCount,
              'vocabSize': e.vocabSize,
              'loss': e.loss,
              'corpusTokens': e.corpusTokens,
            });
          }
        }
        case 'dispose': {
          engine?.dispose();
          engine = null;
          mainSendPort.send({'id': id, 'ok': true});
        }
      }
    } catch (e) {
      mainSendPort.send({'id': id, 'ok': false, 'error': e.toString()});
    }
  });
}

/// Main-isolate handle for the engine worker isolate.
class EngineWorker implements EngineBackend {
  final Isolate _isolate;
  final SendPort _workerPort;
  final ReceivePort _receivePort;
  final Map<int, Completer<Map<String, dynamic>>> _pending = {};
  int _nextId = 1;
  bool _disposed = false;

  EngineWorker._(this._isolate, this._workerPort, this._receivePort) {
    _receivePort.listen((dynamic message) {
      final resp = message as Map<String, dynamic>;
      final id = resp['id'] as int;
      final completer = _pending.remove(id);
      completer?.complete(resp);
    });
  }

  /// Spawn the worker isolate. The native library is loaded lazily on the
  /// first engine call inside the worker.
  static Future<EngineWorker> spawn() async {
    final receivePort = ReceivePort();
    final isolate = await Isolate.spawn(_engineWorkerMain, receivePort.sendPort);
    final workerPort = await receivePort.first as SendPort;
    return EngineWorker._(isolate, workerPort, receivePort);
  }

  Future<Map<String, dynamic>> _send(Map<String, dynamic> cmd) {
    if (_disposed) return Future.value({'ok': false, 'error': 'disposed'});
    final id = _nextId++;
    final completer = Completer<Map<String, dynamic>>();
    _pending[id] = completer;
    _workerPort.send({...cmd, 'id': id});
    return completer.future;
  }

  @override
  Future<bool> create(TrainConfig config) async {
    final r = await _send({'type': 'create', 'config': config.toJson()});
    return r['ok'] as bool? ?? false;
  }

  @override
  Future<bool> setCorpus(String text) async {
    final r = await _send({'type': 'setCorpus', 'text': text});
    return r['ok'] as bool? ?? false;
  }

  /// Train one chunk. Returns the per-step losses (empty on failure).
  @override
  Future<List<double>> trainChunk(int steps) async {
    final r = await _send({'type': 'trainChunk', 'steps': steps});
    if (r['ok'] != true) return const [];
    final raw = r['losses'] as List;
    return raw.map((e) => (e as num).toDouble()).toList();
  }

  @override
  Future<String> generate(
    String prompt, {
    int maxTokens = 64,
    double temperature = 0.8,
    int topK = 40,
    int seed = 0,
  }) async {
    final r = await _send({
      'type': 'generate',
      'prompt': prompt,
      'maxTokens': maxTokens,
      'temperature': temperature,
      'topK': topK,
      'seed': seed,
    });
    if (r['ok'] != true) return '';
    return r['text'] as String? ?? '';
  }

  @override
  Future<bool> saveBrain(String path) async {
    final r = await _send({'type': 'saveBrain', 'path': path});
    return r['ok'] as bool? ?? false;
  }

  @override
  Future<bool> loadBrain(String path) async {
    final r = await _send({'type': 'loadBrain', 'path': path});
    return r['ok'] as bool? ?? false;
  }

  @override
  Future<void> setLr(double lr) async {
    await _send({'type': 'setLr', 'lr': lr});
  }

  @override
  Future<void> setBatchSize(int batch) async {
    await _send({'type': 'setBatchSize', 'batch': batch});
  }

  /// Returns null when there is no brain yet.
  @override
  Future<Map<String, dynamic>?> getInfo() async {
    final r = await _send({'type': 'getInfo'});
    if (r['ok'] != true) return null;
    return r;
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    try {
      await _send({'type': 'dispose'}).timeout(const Duration(seconds: 5));
    } catch (_) {
      // Best effort; the isolate is killed below regardless.
    }
    _receivePort.close();
    _isolate.kill(priority: Isolate.immediate);
  }
}
