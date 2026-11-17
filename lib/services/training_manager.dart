// TrainingManager — the app's state hub (ChangeNotifier). Mirrors B's
// TrainingManager, adapted for Flutter:
//
// - The native engine lives in a background isolate ([EngineWorker]); this
//   class only holds UI state and drives it with high-level commands.
// - Training runs in small chunks (5 steps). Between chunks the main isolate
//   is free, so pause/stop and generation requests take effect promptly and
//   the loss chart updates live.
// - Corpus files live under the app documents directory (corpora/*.txt).
// - The brain autosaves to brain-autosave.brain on stop and is restored
//   on the next launch.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tinytrainer_engine/tinytrainer_engine.dart';

import '../engine/engine_backend.dart';
import '../engine/engine_worker.dart';
import '../engine/direct_engine_backend.dart';
import '../l10n/strings.dart';
import '../models.dart';

class TrainingManager extends ChangeNotifier {
  static const int chunkSteps = 5;
  static const int maxHistoryPoints = 3000;
  static const int maxCorpusChars = 5000000;
  static const String _keyActiveCorpora = 'active_corpora';
  static const String _keyLocale = 'locale';

  final EngineBackend? _injectedBackend;
  final Directory? _injectedDocumentsDir;
  EngineBackend? _backend;

  /// The app documents directory (injected in tests to avoid path_provider).
  Future<Directory> _appDir() async {
    if (_injectedDocumentsDir != null) return _injectedDocumentsDir;
    return getApplicationDocumentsDirectory();
  }

  TrainState _trainState = TrainState.idle;
  TrainState get trainState => _trainState;

  TrainStats _stats = const TrainStats();
  TrainStats get stats => _stats;

  List<(int, double)> _lossHistory = [];
  List<(int, double)> get lossHistory => List.unmodifiable(_lossHistory);

  BrainInfo _brainInfo = const BrainInfo();
  BrainInfo get brainInfo => _brainInfo;

  List<CorpusItem> _corpora = [];
  List<CorpusItem> get corpora => List.unmodifiable(_corpora);

  TrainConfig _config = const TrainConfig();
  TrainConfig get currentConfig => _config;

  bool get hasBrain => _brainInfo.hasBrain;

  String? _message;
  String? get message => _message;

  bool _initialised = false;
  bool _disposed = false;
  // The in-flight initialisation. ensureReady() is called fire-and-forget
  // from initState AND awaited by _requireBackend(); without sharing one
  // Future, a second call returns early (because _initialised is already
  // true) while the worker is still spawning — so _requireBackend() sees
  // a null backend and every brain creation fails with a misleading
  // "超参数超出范围" error. Sharing the Future makes every caller wait
  // for the real initialisation to finish.
  Future<void>? _readyFuture;
  int _totalTokens = 0;
  int _elapsedMs = 0;
  bool _stopRequested = false;
  bool _generating = false;
  bool get generating => _generating;

  String _lastGeneration = '';
  String get lastGeneration => _lastGeneration;

  TrainingManager({EngineBackend? backend, Directory? documentsDir})
      : _injectedBackend = backend,
        _injectedDocumentsDir = documentsDir;

  // ------------------------------------------------------------------
  // Lifecycle
  // ------------------------------------------------------------------

  /// Spawn the worker isolate (once) and restore the autosave + corpora.
  /// If a backend was injected (tests), it is used instead of spawning.
  /// Corpus/autosave restore failures are non-fatal (e.g. path_provider
  /// is unavailable in a widget test) and are swallowed.
  /// Concurrent callers share one initialisation Future (see _readyFuture).
  Future<void> ensureReady() {
    return _readyFuture ??= _ensureReadyImpl();
  }

  Future<void> _ensureReadyImpl() async {
    if (_initialised) return;
    _initialised = true;
    _backend ??= _injectedBackend;
    if (_backend == null) {
      try {
        _backend = await EngineWorker.spawn();
      } catch (e) {
        // Worker isolate unusable on this device: fall back to running the
        // engine on the main isolate (training chunks block the UI briefly,
        // but the app works). The exact cause is kept for diagnostics.
        _backend = DirectEngineBackend();
        _message = '后台引擎启动失败，已切换到主线程引擎：$e';
        notifyListeners();
      }
    }
    try {
      await _refreshCorpora();
    } catch (_) {
      // Non-fatal: corpus list just stays empty.
    }
    try {
      await restoreAutoSaveIfAny();
    } catch (_) {
      // Non-fatal: no autosave to restore.
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _backend?.dispose();
    super.dispose();
  }

  // ensureReady() and the training loop are fire-and-forget async work:
  // they keep calling notifyListeners() after awaits. If the widget tree
  // is disposed first (e.g. a test ending), those calls would throw
  // "used after being disposed". Swallow them — a disposed manager has
  // no listeners left to inform.
  @override
  void notifyListeners() {
    if (_disposed) return;
    super.notifyListeners();
  }

  void _postMessage(String msg) {
    _message = msg;
    notifyListeners();
  }

  /// The UI consumes (and clears) the one-shot message.
  String? takeMessage() {
    final m = _message;
    _message = null;
    return m;
  }

  // ------------------------------------------------------------------
  // Brain lifecycle
  // ------------------------------------------------------------------

  Future<bool> createNewBrain(TrainConfig config) async {
    if (!config.isValid) {
      _postMessage('超参数超出范围，请检查后重试');
      return false;
    }
    var backend = await _requireBackend();
    if (backend == null) {
      // _requireBackend() only returns null when the engine worker failed
      // to spawn; ensureReady() already posted '引擎启动失败：…' in that
      // case, so surface it instead of failing silently (the Brain page
      // used to show the misleading "超参数超出范围" for this path).
      if (_message == null) _postMessage('引擎未就绪，请稍候再试');
      return false;
    }
    var ok = await backend.create(config);
    if (!ok && backend is EngineWorker) {
      // The worker isolate's create failed on this device (the C engine
      // itself is fine — the same code passes on the main isolate). Swap
      // to the direct backend and retry once, instead of leaving the user
      // with a dead "创建大脑失败".
      await backend.dispose();
      final direct = DirectEngineBackend();
      _backend = direct;
      backend = direct;
      ok = await backend.create(config);
    }
    if (!ok) {
      final detail = backend is DirectEngineBackend
          ? (backend.lastError ?? '')
          : '';
      _postMessage(
        detail.isEmpty ? '创建大脑失败' : '创建大脑失败：$detail',
      );
      return false;
    }
    _config = config;
    _resetRunStats();
    await _updateBrainInfo();
    return true;
  }

  Future<bool> loadBrainFile(String path) async {
    final backend = await _requireBackend();
    if (backend == null) return false;
    final ok = await backend.loadBrain(path);
    if (!ok) {
      _postMessage('加载大脑失败：文件可能损坏或版本不匹配');
      return false;
    }
    // Adopt the structure from the .brain header so the Brain tab shows
    // the right architecture.
    final header = _parseBrainHeader(path);
    final model = header?['model'] as Map<String, dynamic>?;
    if (model != null) {
      _config = _config.copyWith(
        nLayer: (model['n_layer'] as num?)?.toInt() ?? _config.nLayer,
        nEmbd: (model['n_embd'] as num?)?.toInt() ?? _config.nEmbd,
        nHead: (model['n_head'] as num?)?.toInt() ?? _config.nHead,
        blockSize: (model['block_size'] as num?)?.toInt() ?? _config.blockSize,
        vocabSize: (model['vocab_size'] as num?)?.toInt() ?? _config.vocabSize,
      );
    }
    _resetRunStats(keepStep: true);
    await _updateBrainInfo();
    return true;
  }

  Future<bool> saveBrainFile(String path) async {
    if (!hasBrain) {
      _postMessage('还没有大脑可以保存');
      return false;
    }
    final backend = await _requireBackend();
    if (backend == null) return false;
    final ok = await backend.saveBrain(path);
    if (!ok) _postMessage('保存大脑失败');
    return ok;
  }

  Future<bool> autoSave() async {
    if (!hasBrain) return false;
    final dir = await _appDir();
    return saveBrainFile('${dir.path}/brain-autosave.brain');
  }

  Future<bool> restoreAutoSaveIfAny() async {
    final dir = await _appDir();
    final f = File('${dir.path}/brain-autosave.brain');
    if (!await f.exists()) return false;
    return loadBrainFile(f.path);
  }

  /// Load the bundled base brain (assets/base.brain). Returns a status:
  /// 'OK' | 'PLACEHOLDER' | 'LOAD_FAILED' | 'ERROR'.
  Future<String> loadBaseBrain() async {
    try {
      final dir = await _appDir();
      final out = File('${dir.path}/base.brain');
      final data = await rootBundle.load('assets/base.brain');
      await out.writeAsBytes(data.buffer.asUint8List());
      // The first release ships a placeholder, not a real .brain.
      // A real .brain starts with the magic "TBRN".
      final bytes = await out.readAsBytes();
      if (bytes.length < 4 ||
          String.fromCharCodes(bytes.sublist(0, 4)) != 'TBRN') {
        await out.delete();
        return 'PLACEHOLDER';
      }
      final ok = await loadBrainFile(out.path);
      return ok ? 'OK' : 'LOAD_FAILED';
    } catch (_) {
      return 'ERROR';
    }
  }

  // ------------------------------------------------------------------
  // Corpus management
  // ------------------------------------------------------------------

  Future<Directory> _corpusDir() async {
    final dir = await _appDir();
    final c = Directory('${dir.path}/corpora');
    if (!await c.exists()) await c.create(recursive: true);
    return c;
  }

  Future<Set<String>> _activeNames() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(_keyActiveCorpora)?.toSet() ?? {};
  }

  Future<void> _saveActiveNames(Set<String> names) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_keyActiveCorpora, names.toList());
  }

  Future<void> _refreshCorpora() async {
    final dir = await _corpusDir();
    final active = await _activeNames();
    final files = dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.txt'))
        .toList()
      ..sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
    _corpora = files
        .map((f) {
          final name = f.uri.pathSegments.last;
          return CorpusItem(
            name: name.replaceAll('.txt', ''),
            sizeBytes: f.lengthSync(),
            active: active.contains(name),
          );
        })
        .toList();
    notifyListeners();
  }

  Future<bool> addCorpus(String rawName, String text) async {
    final clean = text.trim();
    if (clean.isEmpty) return false;
    var base = rawName.trim().isEmpty ? '语料${_corpora.length + 1}' : rawName.trim();
    base = base.replaceAll(RegExp(r'[^A-Za-z0-9_\-\u4e00-\u9fa5]+'), '_');
    if (base.length > 40) base = base.substring(0, 40);
    final dir = await _corpusDir();
    var file = File('${dir.path}/$base.txt');
    var n = 2;
    while (await file.exists()) {
      file = File('${dir.path}/$base($n).txt');
      n++;
    }
    await file.writeAsString(clean);
    final active = await _activeNames()..add(file.uri.pathSegments.last);
    await _saveActiveNames(active);
    await _refreshCorpora();
    return true;
  }

  Future<void> setCorpusActive(String name, bool active) async {
    final names = await _activeNames();
    final fileName = '$name.txt';
    if (active) {
      names.add(fileName);
    } else {
      names.remove(fileName);
    }
    await _saveActiveNames(names);
    await _refreshCorpora();
  }

  Future<void> deleteCorpus(String name) async {
    final dir = await _corpusDir();
    final file = File('${dir.path}/$name.txt');
    if (await file.exists()) await file.delete();
    final names = await _activeNames()..remove('$name.txt');
    await _saveActiveNames(names);
    await _refreshCorpora();
  }

  /// Concatenated text of all active corpora (capped for memory).
  Future<String> buildCorpusText() async {
    final dir = await _corpusDir();
    final sb = StringBuffer();
    for (final item in _corpora.where((c) => c.active)) {
      final file = File('${dir.path}/${item.name}.txt');
      if (!await file.exists()) continue;
      sb.write(await file.readAsString());
      sb.write('\n');
      if (sb.length >= maxCorpusChars) break;
    }
    final text = sb.toString();
    return text.length > maxCorpusChars
        ? text.substring(0, maxCorpusChars)
        : text;
  }

  // ------------------------------------------------------------------
  // Training control
  // ------------------------------------------------------------------

  Future<EngineBackend?> _requireBackend() async {
    if (_backend != null) return _backend;
    await ensureReady();
    return _backend;
  }

  /// Prepare everything for a training run. Returns false on failure.
  Future<bool> prepareForTraining(TrainConfig newConfig) async {
    final corpusText = await buildCorpusText();
    if (corpusText.trim().isEmpty) {
      _postMessage('请先添加至少一份语料并勾选启用');
      return false;
    }
    final backend = await _requireBackend();
    if (backend == null) return false;
    if (!hasBrain) {
      _config = newConfig;
      final ok = await backend.create(newConfig);
      if (!ok) {
        _postMessage('创建大脑失败');
        return false;
      }
    } else if (!_config.structureEquals(newConfig)) {
      // Structure params cannot change on a live brain.
      final ok = await createNewBrain(newConfig);
      if (!ok) return false;
    } else {
      _config = newConfig;
      await backend.setLr(newConfig.lr);
      await backend.setBatchSize(newConfig.batchSize);
    }
    final ok = await backend.setCorpus(corpusText);
    if (!ok) {
      _postMessage('设置语料失败');
      return false;
    }
    await _updateBrainInfo();
    return true;
  }

  void requestStart() {
    _trainState = TrainState.running;
    _stopRequested = false;
    notifyListeners();
    unawaited(_trainingLoop());
  }

  void requestPause() {
    if (_trainState == TrainState.running) {
      _trainState = TrainState.paused;
      notifyListeners();
    }
  }

  void requestResume() {
    if (_trainState == TrainState.paused) {
      _trainState = TrainState.running;
      notifyListeners();
    }
  }

  Future<void> requestStop() async {
    _stopRequested = true;
    _trainState = TrainState.idle;
    notifyListeners();
    await autoSave();
    _postMessage('训练已停止，大脑已保存');
  }

  /// The training loop. Runs on the main isolate but each chunk is a single
  /// round-trip to the worker, so the UI stays responsive between chunks.
  Future<void> _trainingLoop() async {
    final backend = _backend;
    if (backend == null) return;
    while (_trainState == TrainState.running ||
        _trainState == TrainState.paused) {
      if (_stopRequested) break;
      if (_trainState == TrainState.paused) {
        await Future.delayed(const Duration(milliseconds: 200));
        continue;
      }
      final chunkStart = DateTime.now();
      final losses = await backend.trainChunk(chunkSteps);
      if (_stopRequested) break;
      if (losses.isEmpty) {
        await Future.delayed(const Duration(milliseconds: 500));
        continue;
      }
      final chunkMs = DateTime.now().difference(chunkStart).inMilliseconds;
      _elapsedMs += chunkMs;
      _totalTokens += losses.length * _config.batchSize * _config.blockSize;
      final firstStep = _stats.step + 1;
      final step = _stats.step + losses.length;
      final loss = losses.last;
      final tps = _elapsedMs > 0 ? _totalTokens * 1000.0 / _elapsedMs : 0.0;
      _stats = TrainStats(
        step: step,
        loss: loss,
        tokensPerSec: tps,
        elapsedMs: _elapsedMs,
      );
      for (var i = 0; i < losses.length; i++) {
        _lossHistory.add((firstStep + i, losses[i]));
      }
      while (_lossHistory.length > maxHistoryPoints) {
        _lossHistory.removeAt(0);
      }
      _brainInfo = _brainInfo.copyWith(step: step, loss: loss);
      notifyListeners();
      // Yield to the event loop so pause/stop requests and UI timers are
      // never starved by a fast backend (a tight microtask loop would
      // otherwise delay every Future.delayed indefinitely).
      await Future<void>.delayed(Duration.zero);
    }
    if (_trainState == TrainState.idle) {
      // Loop exited via stop; autosave already handled by requestStop.
    }
  }

  // ------------------------------------------------------------------
  // Generation
  // ------------------------------------------------------------------

  Future<void> generate(
    String prompt, {
    int maxTokens = 64,
    double temperature = 0.8,
    int topK = 40,
  }) async {
    if (prompt.trim().isEmpty) {
      _postMessage('请先输入 prompt');
      return;
    }
    if (!hasBrain) {
      _postMessage('还没有大脑，请先去「训练」页开始训练，或去「大脑」页新建/导入');
      return;
    }
    if (_generating) return;
    _generating = true;
    notifyListeners();
    final backend = await _requireBackend();
    String out = '';
    if (backend != null) {
      out = await backend.generate(
        prompt,
        maxTokens: maxTokens,
        temperature: temperature,
        topK: topK,
        seed: DateTime.now().millisecondsSinceEpoch & 0x7fffffff,
      );
    }
    _lastGeneration = out.isEmpty ? '(生成失败)' : prompt + out;
    _generating = false;
    notifyListeners();
  }

  // ------------------------------------------------------------------
  // Helpers
  // ------------------------------------------------------------------

  void _resetRunStats({bool keepStep = false}) {
    final step = keepStep ? _stats.step : 0;
    _totalTokens = 0;
    _elapsedMs = 0;
    _stats = TrainStats(step: step);
    _lossHistory = [];
  }

  Future<void> _updateBrainInfo() async {
    final backend = _backend;
    if (backend == null) {
      _brainInfo = const BrainInfo();
      notifyListeners();
      return;
    }
    final info = await backend.getInfo();
    if (info == null) {
      _brainInfo = const BrainInfo();
    } else {
      _brainInfo = BrainInfo(
        step: (info['step'] as num?)?.toInt() ?? 0,
        paramCount: (info['paramCount'] as num?)?.toInt() ?? 0,
        vocabSize: (info['vocabSize'] as num?)?.toInt() ?? 0,
        nLayer: _config.nLayer,
        nEmbd: _config.nEmbd,
        nHead: _config.nHead,
        blockSize: _config.blockSize,
        loss: (info['loss'] as num?)?.toDouble() ?? double.nan,
      );
    }
    notifyListeners();
  }

  /// Read the .brain header JSON (SPEC section 2): magic "TBRN" | version
  /// u32 LE | header_len u32 LE | header JSON.
  Map<String, dynamic>? _parseBrainHeader(String path) {
    try {
      final bytes = File(path).readAsBytesSync();
      if (bytes.length < 12) return null;
      if (String.fromCharCodes(bytes.sublist(0, 4)) != 'TBRN') return null;
      final headerLen = bytes[8] |
          (bytes[9] << 8) |
          (bytes[10] << 16) |
          (bytes[11] << 24);
      if (headerLen <= 0 || headerLen > 1000000) return null;
      if (bytes.length < 12 + headerLen) return null;
      final headerBytes = bytes.sublist(12, 12 + headerLen);
      final json = jsonDecode(utf8.decode(headerBytes));
      return json as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  /// Persist the UI locale choice.
  static Future<void> saveLocale(AppLocale locale) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyLocale, locale.name);
  }

  static Future<AppLocale> loadLocale() async {
    final prefs = await SharedPreferences.getInstance();
    final name = prefs.getString(_keyLocale);
    return name == 'en' ? AppLocale.en : AppLocale.zh;
  }
}
