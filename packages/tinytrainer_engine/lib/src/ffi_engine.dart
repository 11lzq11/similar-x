// TinyTrainerEngine — the real [Engine], backed by the C engine via
// dart:ffi (see tinytrainer_engine_bindings_generated.dart).
//
// Threading: the C engine is NOT thread-safe for concurrent calls on the
// same model. The app serialises all calls that touch weights through a
// single lock (see the app's TrainingManager) and runs trainSteps on a
// background isolate. This class itself does no locking.
import 'dart:ffi' as ffi;

import 'package:ffi/ffi.dart';

import 'config.dart';
import 'engine.dart';
import '../tinytrainer_engine_bindings_generated.dart' as native;

class TinyTrainerEngine implements Engine {
  final ffi.Pointer<native.TGModel> _model;
  bool _disposed = false;

  TinyTrainerEngine._(this._model);

  /// Create a brand-new model from [config] (random init). Returns null
  /// when the config is invalid or the native allocation fails.
  static TinyTrainerEngine? create(TrainConfig config) {
    if (!config.isValid) return null;
    final cfgPtr = calloc<native.TGConfig>();
    try {
      cfgPtr.ref
        ..nLayer = config.nLayer
        ..nEmbd = config.nEmbd
        ..nHead = config.nHead
        ..blockSize = config.blockSize
        ..vocabSize = config.vocabSize
        ..lr = config.lr
        ..batchSize = config.batchSize
        ..warmupSteps = config.warmupSteps
        ..decaySteps = config.decaySteps
        ..weightDecay = config.weightDecay
        ..gradClip = config.gradClip
        ..beta1 = config.beta1
        ..beta2 = config.beta2
        ..eps = config.eps
        ..seed = config.seed;
      if (native.tgConfigValidate(cfgPtr) != 0) return null;
      final model = native.tgCreate(cfgPtr);
      if (model == ffi.nullptr) return null;
      return TinyTrainerEngine._(model);
    } finally {
      calloc.free(cfgPtr);
    }
  }

  /// Load a .brain file. Returns null when the file is missing, corrupt,
  /// or has an unsupported version.
  static TinyTrainerEngine? loadBrain(String path) {
    final pathPtr = path.toNativeUtf8();
    try {
      final model = native.tgLoadBrain(pathPtr);
      if (model == ffi.nullptr) return null;
      return TinyTrainerEngine._(model);
    } finally {
      calloc.free(pathPtr);
    }
  }

  void _checkAlive() {
    if (_disposed) throw StateError('TinyTrainerEngine is disposed');
  }

  @override
  bool get isDisposed => _disposed;

  @override
  int get paramCount {
    _checkAlive();
    return native.tgParamCount(_model);
  }

  @override
  int get vocabSize {
    _checkAlive();
    return native.tgVocabSize(_model);
  }

  @override
  int get step {
    _checkAlive();
    return native.tgGetStep(_model);
  }

  @override
  double get loss {
    _checkAlive();
    return native.tgGetLoss(_model);
  }

  @override
  int get corpusTokens {
    _checkAlive();
    return native.tgCorpusTokens(_model);
  }

  @override
  void setLr(double lr) {
    _checkAlive();
    native.tgSetLr(_model, lr);
  }

  @override
  void setBatchSize(int batch) {
    _checkAlive();
    native.tgSetBatchSize(_model, batch);
  }

  @override
  bool setCorpus(String text) {
    _checkAlive();
    if (text.isEmpty) return false;
    final textPtr = text.toNativeUtf8();
    try {
      return native.tgSetCorpus(_model, textPtr) == 0;
    } finally {
      calloc.free(textPtr);
    }
  }

  @override
  List<double> trainSteps(int steps) {
    _checkAlive();
    if (steps <= 0) return const [];
    final lossesPtr = calloc<ffi.Float>(steps);
    try {
      final rc = native.tgTrainSteps(_model, steps, lossesPtr);
      if (rc != 0) return const [];
      return List<double>.generate(steps, (i) => lossesPtr[i]);
    } finally {
      calloc.free(lossesPtr);
    }
  }

  @override
  String generate(
    String prompt, {
    int maxTokens = 64,
    double temperature = 0.8,
    int topK = 40,
    int seed = 0,
  }) {
    _checkAlive();
    if (prompt.isEmpty || maxTokens <= 0) return '';
    // Char-level vocab: one token is one char (<= 3 bytes in UTF-8 for
    // CJK, 4 for emoji). 4 bytes/token + margin is a safe bound.
    final cap = maxTokens * 4 + 64;
    final promptPtr = prompt.toNativeUtf8();
    final outPtr = calloc<ffi.Uint8>(cap);
    try {
      final n = native.tgGenerate(
        _model,
        promptPtr,
        maxTokens,
        temperature,
        topK,
        seed,
        outPtr.cast<Utf8>(),
        cap,
      );
      if (n < 0) return '';
      if (n == 0) return '';
      return outPtr.cast<Utf8>().toDartString(length: n);
    } finally {
      calloc.free(promptPtr);
      calloc.free(outPtr);
    }
  }

  @override
  bool saveBrain(String path) {
    _checkAlive();
    final pathPtr = path.toNativeUtf8();
    try {
      return native.tgSaveBrain(_model, pathPtr) == 0;
    } finally {
      calloc.free(pathPtr);
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    native.tgFree(_model);
  }
}
