// EngineWorker integration test: spawns the real worker isolate (real
// native library via the build hook) and trains a small model for real.
// This verifies the isolate + FFI path the app actually uses.
//
// NOTE: this test needs a C compiler on PATH for the build hook. On this VM
// the NDK Clang (or a gcc-as-clang shim in ~/bin) satisfies it; on CI the
// runner provides Clang. It is slowish (~1 min for the small training run)
// because the VM is single-core-ish.
import 'package:flutter_test/flutter_test.dart';
import 'package:tinytrainer_engine/tinytrainer_engine.dart';
import 'package:tiny_trainer/engine/engine_worker.dart';

const _corpus =
    '小白猫坐在窗台上，看着外面的雨。雨停了，太阳出来了，小白猫跑到院子里玩。'
    '小明每天早上都去跑步，跑完步吃早饭，然后去上学。学校里有很多同学，大家一起读书写字。'
    '春天来了，花开了，鸟儿在枝头唱歌。农民伯伯在田里种庄稼，汗水滴进泥土里。';

void main() {
  test('worker: create + corpus + train + generate', () async {
    final worker = await EngineWorker.spawn();
    addTearDown(worker.dispose);

    final created = await worker.create(
      const TrainConfig(
        nLayer: 2,
        nEmbd: 64,
        nHead: 2,
        blockSize: 64,
        vocabSize: 500,
        batchSize: 4,
        lr: 3e-3,
      ),
    );
    expect(created, isTrue);

    expect(await worker.setCorpus(_corpus), isTrue);

    final losses = await worker.trainChunk(10);
    expect(losses.length, 10);
    expect(losses.last, lessThan(losses.first),
        reason: 'loss should drop: $losses');

    final info = await worker.getInfo();
    expect(info, isNotNull);
    expect(info!['step'], 10);
    expect(info['paramCount'], greaterThan(0));

    final text = await worker.generate(
      '小白猫',
      maxTokens: 16,
      temperature: 0.8,
      topK: 40,
      seed: 7,
    );
    expect(text, isNotEmpty);
  }, timeout: const Timeout(Duration(minutes: 3)));
}
