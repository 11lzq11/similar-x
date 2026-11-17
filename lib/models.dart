// App-side models. Mirrors B's Models.kt (TrainConfig lives in the
// tinytrainer_engine package; this file holds the UI-facing state types).

/// Live training state.
enum TrainState { idle, running, paused }

/// Live training numbers shown on the Train tab.
class TrainStats {
  final int step;
  final double loss; // NaN until the first step
  final double tokensPerSec;
  final int elapsedMs;

  const TrainStats({
    this.step = 0,
    this.loss = double.nan,
    this.tokensPerSec = 0,
    this.elapsedMs = 0,
  });

  TrainStats copyWith({
    int? step,
    double? loss,
    double? tokensPerSec,
    int? elapsedMs,
  }) =>
      TrainStats(
        step: step ?? this.step,
        loss: loss ?? this.loss,
        tokensPerSec: tokensPerSec ?? this.tokensPerSec,
        elapsedMs: elapsedMs ?? this.elapsedMs,
      );
}

/// Info shown on the Brain tab.
class BrainInfo {
  final int step;
  final int paramCount;
  final int vocabSize;
  final int nLayer;
  final int nEmbd;
  final int nHead;
  final int blockSize;
  final double loss; // NaN until a step has run

  const BrainInfo({
    this.step = 0,
    this.paramCount = 0,
    this.vocabSize = 0,
    this.nLayer = 0,
    this.nEmbd = 0,
    this.nHead = 0,
    this.blockSize = 0,
    this.loss = double.nan,
  });

  bool get hasBrain => nLayer > 0;

  String archString() => hasBrain
      ? '$nLayer层 · 隐藏层 $nEmbd · $nHead头 · 序列 $blockSize'
      : '—';

  BrainInfo copyWith({
    int? step,
    int? paramCount,
    int? vocabSize,
    int? nLayer,
    int? nEmbd,
    int? nHead,
    int? blockSize,
    double? loss,
  }) =>
      BrainInfo(
        step: step ?? this.step,
        paramCount: paramCount ?? this.paramCount,
        vocabSize: vocabSize ?? this.vocabSize,
        nLayer: nLayer ?? this.nLayer,
        nEmbd: nEmbd ?? this.nEmbd,
        nHead: nHead ?? this.nHead,
        blockSize: blockSize ?? this.blockSize,
        loss: loss ?? this.loss,
      );
}

/// One corpus file stored under the app documents directory.
class CorpusItem {
  final String name;
  final int sizeBytes;
  final bool active;

  const CorpusItem({
    required this.name,
    required this.sizeBytes,
    required this.active,
  });

  CorpusItem copyWith({String? name, int? sizeBytes, bool? active}) =>
      CorpusItem(
        name: name ?? this.name,
        sizeBytes: sizeBytes ?? this.sizeBytes,
        active: active ?? this.active,
      );
}
