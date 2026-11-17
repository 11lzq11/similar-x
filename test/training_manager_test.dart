// TrainingManager tests (fake backend + temp documents dir).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tinytrainer_engine/tinytrainer_engine.dart';
import 'package:tiny_trainer/models.dart';
import 'package:tiny_trainer/services/training_manager.dart';

import 'fake_engine_backend.dart';

void main() {
  late Directory tmpDir;
  late FakeEngineBackend backend;
  late TrainingManager manager;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tmpDir = await Directory.systemTemp.createTemp('tiny_trainer_app_test');
    backend = FakeEngineBackend();
    manager = TrainingManager(backend: backend, documentsDir: tmpDir);
    await manager.ensureReady();
  });

  tearDown(() async {
    manager.dispose();
    if (await tmpDir.exists()) await tmpDir.delete(recursive: true);
  });

  test('corpus add / activate / delete', () async {
    expect(manager.corpora, isEmpty);
    expect(await manager.addCorpus('test1', '小白猫坐在窗台上。'), isTrue);
    expect(manager.corpora.length, 1);
    expect(manager.corpora.first.name, 'test1');
    expect(manager.corpora.first.active, isTrue);
    await manager.setCorpusActive('test1', false);
    expect(manager.corpora.first.active, isFalse);
    await manager.setCorpusActive('test1', true);
    expect(manager.corpora.first.active, isTrue);
    final text = await manager.buildCorpusText();
    expect(text, contains('小白猫'));
    await manager.deleteCorpus('test1');
    expect(manager.corpora, isEmpty);
  });

  test('addCorpus rejects empty text', () async {
    expect(await manager.addCorpus('empty', '   '), isFalse);
    expect(manager.corpora, isEmpty);
  });

  test('prepareForTraining requires a corpus', () async {
    final ok = await manager.prepareForTraining(const TrainConfig());
    expect(ok, isFalse);
    expect(manager.takeMessage(), isNotNull);
  });

  test('prepareForTraining creates a brain and sets corpus', () async {
    await manager.addCorpus('c1', '小白猫坐在窗台上，看着外面的雨。' * 20);
    final ok = await manager.prepareForTraining(const TrainConfig());
    expect(ok, isTrue);
    expect(backend.createdConfig, isNotNull);
    expect(backend.corpusText, contains('小白猫'));
    expect(manager.hasBrain, isTrue);
    expect(manager.brainInfo.paramCount, 2400000);
  });

  test('start/pause/resume/stop training loop accumulates loss', () async {
    await manager.addCorpus('c1', '小白猫坐在窗台上，看着外面的雨。' * 20);
    expect(await manager.prepareForTraining(const TrainConfig()), isTrue);
    manager.requestStart();
    expect(manager.trainState, TrainState.running);
    // Let a few chunks run (fake backend is instant).
    await Future.delayed(const Duration(milliseconds: 300));
    manager.requestPause();
    expect(manager.trainState, TrainState.paused);
    final stepAfterPause = manager.stats.step;
    expect(stepAfterPause, greaterThan(0));
    expect(manager.lossHistory, isNotEmpty);
    expect(manager.lossHistory.last.$2, lessThan(5.0));
    manager.requestResume();
    expect(manager.trainState, TrainState.running);
    await Future.delayed(const Duration(milliseconds: 200));
    await manager.requestStop();
    expect(manager.trainState, TrainState.idle);
    expect(manager.stats.step, greaterThan(stepAfterPause));
    // Stop autosaves.
    expect(backend.savedPaths, isNotEmpty);
  });

  test('generate returns prompt + continuation', () async {
    await manager.addCorpus('c1', '小白猫坐在窗台上。' * 20);
    expect(await manager.prepareForTraining(const TrainConfig()), isTrue);
    await manager.generate('小白猫', maxTokens: 20);
    expect(manager.lastGeneration, startsWith('小白猫'));
    expect(manager.lastGeneration, contains('假生成'));
  });

  test('generate without a brain shows a message', () async {
    await manager.generate('hello');
    expect(manager.takeMessage(), isNotNull);
    expect(manager.lastGeneration, isEmpty);
  });

  test('createNewBrain rejects an invalid config', () async {
    final ok = await manager.createNewBrain(
      const TrainConfig(nEmbd: 100, nHead: 3),
    );
    expect(ok, isFalse);
  });

  test('loadBrainFile adopts structure from the header', () async {
    // Write a minimal fake .brain: magic + version + headerLen + header JSON.
    // The fake backend's loadBrain returns true regardless of content, but
    // the manager parses the header for the structure.
    final headerJson =
        '{"model":{"n_layer":3,"n_embd":128,"n_head":4,"block_size":64,"vocab_size":2000},"vocab":[],"train":{"step":100}}';
    final headerBytes = headerJson.codeUnits;
    final bytes = <int>[
      ...'TBRN'.codeUnits,
      1, 0, 0, 0, // version
      headerBytes.length & 0xff,
      (headerBytes.length >> 8) & 0xff,
      (headerBytes.length >> 16) & 0xff,
      (headerBytes.length >> 24) & 0xff,
      ...headerBytes,
    ];
    final file = File('${tmpDir.path}/fake.brain');
    await file.writeAsBytes(bytes);
    final ok = await manager.loadBrainFile(file.path);
    expect(ok, isTrue);
    expect(manager.currentConfig.nLayer, 3);
    expect(manager.currentConfig.nEmbd, 128);
    expect(manager.currentConfig.blockSize, 64);
  });
}
