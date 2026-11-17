// Real FFI test: exercises the C engine through the Dart FFI bindings.
// This test runs the native library (built by hook/build.dart via the
// native-assets system) — it trains a small model for real and checks that
// loss drops, generation produces text, and save/load round-trips.
import 'dart:io';

import 'package:test/test.dart';
import 'package:tinytrainer_engine/tinytrainer_engine.dart';

const _corpus =
    '小白猫坐在窗台上，看着外面的雨。雨停了，太阳出来了，小白猫跑到院子里玩。'
    '小明每天早上都去跑步，跑完步吃早饭，然后去上学。学校里有很多同学，大家一起读书写字。'
    '春天来了，花开了，鸟儿在枝头唱歌。农民伯伯在田里种庄稼，汗水滴进泥土里。'
    '小红有一支铅笔，她用铅笔写字画画。她的画很好看，老师常常表扬她。';

void main() {
  test('create + setCorpus + paramCount', () {
    final engine = TinyTrainerEngine.create(
      const TrainConfig(
        nLayer: 2,
        nEmbd: 64,
        nHead: 2,
        blockSize: 64,
        vocabSize: 500,
        batchSize: 4,
      ),
    );
    expect(engine, isNotNull);
    addTearDown(engine!.dispose);
    expect(engine.paramCount, greaterThan(0));
    expect(engine.setCorpus(_corpus), isTrue);
    expect(engine.vocabSize, greaterThan(10));
    expect(engine.corpusTokens, greaterThan(50));
  });

  test('train 30 steps: loss drops', () {
    final engine = TinyTrainerEngine.create(
      const TrainConfig(
        nLayer: 2,
        nEmbd: 64,
        nHead: 2,
        blockSize: 64,
        vocabSize: 500,
        batchSize: 4,
        lr: 3e-3,
      ),
    )!;
    addTearDown(engine.dispose);
    expect(engine.setCorpus(_corpus), isTrue);
    final losses = engine.trainSteps(30);
    expect(losses.length, 30);
    final first = losses.take(5).reduce((a, b) => a + b) / 5;
    final last = losses.skip(25).reduce((a, b) => a + b) / 5;
    // Loss must drop clearly (small model, tiny corpus, 30 steps).
    // Observed: 4.54 -> 3.73 (~18% drop). 0.9 leaves margin.
    expect(last, lessThan(first * 0.9),
        reason: 'first5=$first last5=$last');
    expect(engine.step, 30);
  });

  test('generate returns text after training', () {
    final engine = TinyTrainerEngine.create(
      const TrainConfig(
        nLayer: 2,
        nEmbd: 64,
        nHead: 2,
        blockSize: 64,
        vocabSize: 500,
        batchSize: 4,
        lr: 3e-3,
      ),
    )!;
    addTearDown(engine.dispose);
    expect(engine.setCorpus(_corpus), isTrue);
    engine.trainSteps(30);
    final out = engine.generate(
      '小白猫',
      maxTokens: 20,
      temperature: 0.8,
      topK: 40,
      seed: 42,
    );
    expect(out, isNotEmpty);
  });

  test('save/load round-trip preserves step', () async {
    final engine = TinyTrainerEngine.create(
      const TrainConfig(
        nLayer: 2,
        nEmbd: 64,
        nHead: 2,
        blockSize: 64,
        vocabSize: 500,
        batchSize: 4,
        lr: 3e-3,
      ),
    )!;
    addTearDown(engine.dispose);
    expect(engine.setCorpus(_corpus), isTrue);
    engine.trainSteps(10);
    final tmp = await Directory.systemTemp.createTemp('tiny_trainer_test');
    addTearDown(() => tmp.delete(recursive: true));
    final path = '${tmp.path}/brain.brain';
    expect(engine.saveBrain(path), isTrue);
    expect(File(path).existsSync(), isTrue);
    final loaded = TinyTrainerEngine.loadBrain(path);
    expect(loaded, isNotNull);
    addTearDown(loaded!.dispose);
    expect(loaded.step, engine.step);
    expect(loaded.paramCount, engine.paramCount);
  });

  test('invalid config returns null', () {
    // n_head does not divide n_embd.
    final engine = TinyTrainerEngine.create(
      const TrainConfig(nEmbd: 100, nHead: 3),
    );
    expect(engine, isNull);
  });
}
