// TrainConfig — Dart-side hyper-parameters, mirrors TGConfig in tinygpt.h.
// Defaults match the engine defaults (SPEC section 1) and the corrected
// speed guidance: default batchSize is 8 (a Snapdragon 6 trains noticeably
// faster per step with a small batch; fine-tuning a base works fine with it).
class TrainConfig {
  final int nLayer;
  final int nEmbd;
  final int nHead;
  final int blockSize;
  final int vocabSize;
  final double lr;
  final int batchSize;
  final int warmupSteps;
  final int decaySteps;
  final double weightDecay;
  final double gradClip;
  final double beta1;
  final double beta2;
  final double eps;
  final int seed;

  const TrainConfig({
    this.nLayer = 4,
    this.nEmbd = 192,
    this.nHead = 4,
    this.blockSize = 128,
    this.vocabSize = 3000,
    this.lr = 3e-4,
    this.batchSize = 8,
    this.warmupSteps = 100,
    this.decaySteps = 10000,
    this.weightDecay = 0.01,
    this.gradClip = 1.0,
    this.beta1 = 0.9,
    this.beta2 = 0.95,
    this.eps = 1e-8,
    this.seed = 1337,
  });

  /// SPEC ranges: vocab 500–8000, block 64–256, layers 1–6, embd 64–384,
  /// heads 2–8 and must divide nEmbd, lr 1e-5–1e-2, batch 1–128.
  bool get isValid {
    if (lr < 1e-5 || lr > 1e-2) return false;
    if (batchSize < 1 || batchSize > 128) return false;
    if (blockSize < 64 || blockSize > 256) return false;
    if (nLayer < 1 || nLayer > 6) return false;
    if (nEmbd < 64 || nEmbd > 384) return false;
    if (nHead < 2 || nHead > 8) return false;
    if (nEmbd % nHead != 0) return false;
    if (vocabSize < 500 || vocabSize > 8000) return false;
    if (warmupSteps < 0 || warmupSteps > 5000) return false;
    if (weightDecay < 0 || weightDecay > 0.5) return false;
    if (decaySteps < 1) return false;
    return true;
  }

  /// Only the structure fields (changing these on a live brain requires
  /// creating a new brain; lr/batchSize are live-tunable).
  bool structureEquals(TrainConfig other) =>
      nLayer == other.nLayer &&
      nEmbd == other.nEmbd &&
      nHead == other.nHead &&
      blockSize == other.blockSize &&
      vocabSize == other.vocabSize;

  TrainConfig copyWith({
    int? nLayer,
    int? nEmbd,
    int? nHead,
    int? blockSize,
    int? vocabSize,
    double? lr,
    int? batchSize,
    int? warmupSteps,
    int? decaySteps,
    double? weightDecay,
    double? gradClip,
    double? beta1,
    double? beta2,
    double? eps,
    int? seed,
  }) =>
      TrainConfig(
        nLayer: nLayer ?? this.nLayer,
        nEmbd: nEmbd ?? this.nEmbd,
        nHead: nHead ?? this.nHead,
        blockSize: blockSize ?? this.blockSize,
        vocabSize: vocabSize ?? this.vocabSize,
        lr: lr ?? this.lr,
        batchSize: batchSize ?? this.batchSize,
        warmupSteps: warmupSteps ?? this.warmupSteps,
        decaySteps: decaySteps ?? this.decaySteps,
        weightDecay: weightDecay ?? this.weightDecay,
        gradClip: gradClip ?? this.gradClip,
        beta1: beta1 ?? this.beta1,
        beta2: beta2 ?? this.beta2,
        eps: eps ?? this.eps,
        seed: seed ?? this.seed,
      );

  String archString() => '$nLayer层 · 隐藏层 $nEmbd · $nHead头 · 序列 $blockSize';

  Map<String, dynamic> toJson() => {
        'n_layer': nLayer,
        'n_embd': nEmbd,
        'n_head': nHead,
        'block_size': blockSize,
        'vocab_size': vocabSize,
        'lr': lr,
        'batch_size': batchSize,
        'warmup_steps': warmupSteps,
        'decay_steps': decaySteps,
        'weight_decay': weightDecay,
        'grad_clip': gradClip,
        'beta1': beta1,
        'beta2': beta2,
        'eps': eps,
        'seed': seed,
      };

  static TrainConfig fromJson(Map<String, dynamic> json) => TrainConfig(
        nLayer: (json['n_layer'] as num?)?.toInt() ?? 4,
        nEmbd: (json['n_embd'] as num?)?.toInt() ?? 192,
        nHead: (json['n_head'] as num?)?.toInt() ?? 4,
        blockSize: (json['block_size'] as num?)?.toInt() ?? 128,
        vocabSize: (json['vocab_size'] as num?)?.toInt() ?? 3000,
        lr: (json['lr'] as num?)?.toDouble() ?? 3e-4,
        batchSize: (json['batch_size'] as num?)?.toInt() ?? 8,
        warmupSteps: (json['warmup_steps'] as num?)?.toInt() ?? 100,
        decaySteps: (json['decay_steps'] as num?)?.toInt() ?? 10000,
        weightDecay: (json['weight_decay'] as num?)?.toDouble() ?? 0.01,
        gradClip: (json['grad_clip'] as num?)?.toDouble() ?? 1.0,
        beta1: (json['beta1'] as num?)?.toDouble() ?? 0.9,
        beta2: (json['beta2'] as num?)?.toDouble() ?? 0.95,
        eps: (json['eps'] as num?)?.toDouble() ?? 1e-8,
        seed: (json['seed'] as num?)?.toInt() ?? 1337,
      );
}
