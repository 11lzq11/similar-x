// Hand-rolled zh/en strings (no codegen). The app defaults to Chinese;
// the user can switch language on the Brain tab. Add a key here and in
// both maps when adding UI text.
import 'package:material_ui/material_ui.dart';

enum AppLocale { zh, en }

class Strings {
  final AppLocale locale;

  const Strings(this.locale);

  /// Convenience accessor (delegates to StringsScope).
  static Strings of(BuildContext context) => StringsScope.of(context);

  bool get isZh => locale == AppLocale.zh;

  String _get(String key) => _values[key]?[locale] ?? _values[key]?[AppLocale.zh] ?? key;

  // --- App ---
  String get appTitle => _get('appTitle');
  String get tabTrain => _get('tabTrain');
  String get tabChat => _get('tabChat');
  String get tabBrain => _get('tabBrain');

  // --- Train tab ---
  String get trainTitle => _get('trainTitle');
  String get corpusSection => _get('corpusSection');
  String get addCorpusPaste => _get('addCorpusPaste');
  String get addCorpusFile => _get('addCorpusFile');
  String get corpusNameHint => _get('corpusNameHint');
  String get corpusTextHint => _get('corpusTextHint');
  String get noCorpus => _get('noCorpus');
  String get hyperSection => _get('hyperSection');
  String get lr => _get('lr');
  String get batchSize => _get('batchSize');
  String get blockSize => _get('blockSize');
  String get nLayer => _get('nLayer');
  String get nEmbd => _get('nEmbd');
  String get nHead => _get('nHead');
  String get vocabSize => _get('vocabSize');
  String get warmup => _get('warmup');
  String get weightDecay => _get('weightDecay');
  String get startTraining => _get('startTraining');
  String get pause => _get('pause');
  String get resume => _get('resume');
  String get stop => _get('stop');
  String get step => _get('step');
  String get loss => _get('loss');
  String get tokensPerSec => _get('tokensPerSec');
  String get elapsed => _get('elapsed');
  String get noBrainYet => _get('noBrainYet');

  // --- Chat tab ---
  String get chatTitle => _get('chatTitle');
  String get promptHint => _get('promptHint');
  String get generate => _get('generate');
  String get generating => _get('generating');
  String get temperature => _get('temperature');
  String get topK => _get('topK');
  String get maxTokens => _get('maxTokens');
  String get noBrainChat => _get('noBrainChat');

  // --- Brain tab ---
  String get brainTitle => _get('brainTitle');
  String get brainInfo => _get('brainInfo');
  String get arch => _get('arch');
  String get params => _get('params');
  String get vocab => _get('vocab');
  String get exportBrain => _get('exportBrain');
  String get importBrain => _get('importBrain');
  String get newBrain => _get('newBrain');
  String get loadBaseBrain => _get('loadBaseBrain');
  String get language => _get('language');
  String get aboutPerf => _get('aboutPerf');

  // --- Messages ---
  String get msgNeedCorpus => _get('msgNeedCorpus');
  String get msgTrainingStarted => _get('msgTrainingStarted');
  String get msgTrainingStopped => _get('msgTrainingStopped');
  String get msgBrainSaved => _get('msgBrainSaved');
  String get msgBrainExported => _get('msgBrainExported');
  String get msgBrainImported => _get('msgBrainImported');
  String get msgBrainCreated => _get('msgBrainCreated');
  String get msgBaseBrainLoaded => _get('msgBaseBrainLoaded');
  String get msgBaseBrainPlaceholder => _get('msgBaseBrainPlaceholder');
  String get msgLoadFailed => _get('msgLoadFailed');
  String get msgSaveFailed => _get('msgSaveFailed');
  String get msgInvalidParams => _get('msgInvalidParams');
  String get msgEnterPrompt => _get('msgEnterPrompt');
  String get msgNoBrain => _get('msgNoBrain');
  String get msgGenFailed => _get('msgGenFailed');
  String get msgCorpusAdded => _get('msgCorpusAdded');
  String get msgCorpusEmpty => _get('msgCorpusEmpty');
  String get msgImportFailed => _get('msgImportFailed');
  String get msgStructureChange => _get('msgStructureChange');

  static const Map<String, Map<AppLocale, String>> _values = {
    'appTitle': {AppLocale.zh: 'TinyTrainer', AppLocale.en: 'TinyTrainer'},
    'tabTrain': {AppLocale.zh: '训练', AppLocale.en: 'Train'},
    'tabChat': {AppLocale.zh: '对话', AppLocale.en: 'Chat'},
    'tabBrain': {AppLocale.zh: '大脑', AppLocale.en: 'Brain'},
    'trainTitle': {AppLocale.zh: '训练', AppLocale.en: 'Train'},
    'corpusSection': {AppLocale.zh: '语料', AppLocale.en: 'Corpus'},
    'addCorpusPaste': {AppLocale.zh: '粘贴文本', AppLocale.en: 'Paste text'},
    'addCorpusFile': {AppLocale.zh: '导入 .txt', AppLocale.en: 'Import .txt'},
    'corpusNameHint': {AppLocale.zh: '语料名称', AppLocale.en: 'Corpus name'},
    'corpusTextHint': {
      AppLocale.zh: '粘贴语料文本（越集中越好，同一个领域/风格）',
      AppLocale.en: 'Paste corpus text (keep it focused: one domain/style)',
    },
    'noCorpus': {
      AppLocale.zh: '还没有语料。粘贴文本或导入 .txt 文件，勾选后开始训练。',
      AppLocale.en: 'No corpus yet. Paste text or import a .txt file, tick it, then train.',
    },
    'hyperSection': {AppLocale.zh: '超参数', AppLocale.en: 'Hyper-parameters'},
    'lr': {AppLocale.zh: '学习率', AppLocale.en: 'Learning rate'},
    'batchSize': {AppLocale.zh: 'Batch', AppLocale.en: 'Batch'},
    'blockSize': {AppLocale.zh: '序列长度', AppLocale.en: 'Seq length'},
    'nLayer': {AppLocale.zh: '层数', AppLocale.en: 'Layers'},
    'nEmbd': {AppLocale.zh: '隐藏层', AppLocale.en: 'Hidden'},
    'nHead': {AppLocale.zh: '头数', AppLocale.en: 'Heads'},
    'vocabSize': {AppLocale.zh: '词表大小', AppLocale.en: 'Vocab size'},
    'warmup': {AppLocale.zh: 'Warmup 步数', AppLocale.en: 'Warmup steps'},
    'weightDecay': {AppLocale.zh: '权重衰减', AppLocale.en: 'Weight decay'},
    'startTraining': {AppLocale.zh: '开始训练', AppLocale.en: 'Start training'},
    'pause': {AppLocale.zh: '暂停', AppLocale.en: 'Pause'},
    'resume': {AppLocale.zh: '继续', AppLocale.en: 'Resume'},
    'stop': {AppLocale.zh: '停止', AppLocale.en: 'Stop'},
    'step': {AppLocale.zh: 'Step', AppLocale.en: 'Step'},
    'loss': {AppLocale.zh: 'LOSS', AppLocale.en: 'LOSS'},
    'tokensPerSec': {AppLocale.zh: 'tokens/s', AppLocale.en: 'tokens/s'},
    'elapsed': {AppLocale.zh: '已用时间', AppLocale.en: 'Elapsed'},
    'noBrainYet': {
      AppLocale.zh: '还没有大脑。先添加语料并开始训练，或去「大脑」页新建/导入。',
      AppLocale.en: 'No brain yet. Add a corpus and start training, or create/import one on the Brain tab.',
    },
    'chatTitle': {AppLocale.zh: '对话', AppLocale.en: 'Chat'},
    'promptHint': {AppLocale.zh: '输入开头…', AppLocale.en: 'Type a prompt…'},
    'generate': {AppLocale.zh: '生成', AppLocale.en: 'Generate'},
    'generating': {AppLocale.zh: '生成中…', AppLocale.en: 'Generating…'},
    'temperature': {AppLocale.zh: '温度', AppLocale.en: 'Temperature'},
    'topK': {AppLocale.zh: 'Top-K', AppLocale.en: 'Top-K'},
    'maxTokens': {AppLocale.zh: '最大长度', AppLocale.en: 'Max length'},
    'noBrainChat': {
      AppLocale.zh: '还没有大脑，请先去「训练」页开始训练，或去「大脑」页新建/导入。',
      AppLocale.en: 'No brain yet. Start training on the Train tab, or create/import one on the Brain tab.',
    },
    'brainTitle': {AppLocale.zh: '大脑', AppLocale.en: 'Brain'},
    'brainInfo': {AppLocale.zh: '大脑信息', AppLocale.en: 'Brain info'},
    'arch': {AppLocale.zh: '结构', AppLocale.en: 'Architecture'},
    'params': {AppLocale.zh: '参数量', AppLocale.en: 'Parameters'},
    'vocab': {AppLocale.zh: '词表', AppLocale.en: 'Vocab'},
    'exportBrain': {AppLocale.zh: '导出大脑 (.brain)', AppLocale.en: 'Export brain (.brain)'},
    'importBrain': {AppLocale.zh: '导入大脑 (.brain)', AppLocale.en: 'Import brain (.brain)'},
    'newBrain': {AppLocale.zh: '新建大脑', AppLocale.en: 'New brain'},
    'loadBaseBrain': {AppLocale.zh: '加载底座大脑', AppLocale.en: 'Load base brain'},
    'language': {AppLocale.zh: '语言', AppLocale.en: 'Language'},
    'aboutPerf': {
      AppLocale.zh: '性能：骁龙 6 上默认配置约 10–35 步/分钟（batch 32）；batch 8 步数更快。训几千步后在语料领域内能说通顺的句子。',
      AppLocale.en: 'Performance: ~10–35 steps/min on a Snapdragon 6 at default settings (batch 32); batch 8 steps faster. Coherent in-domain sentences after a few thousand steps.',
    },
    'msgNeedCorpus': {
      AppLocale.zh: '请先添加至少一份语料并勾选启用',
      AppLocale.en: 'Add at least one corpus and tick it first',
    },
    'msgTrainingStarted': {
      AppLocale.zh: '训练已开始',
      AppLocale.en: 'Training started',
    },
    'msgTrainingStopped': {
      AppLocale.zh: '训练已停止，大脑已保存',
      AppLocale.en: 'Training stopped, brain saved',
    },
    'msgBrainSaved': {AppLocale.zh: '大脑已保存', AppLocale.en: 'Brain saved'},
    'msgBrainExported': {AppLocale.zh: '大脑已导出', AppLocale.en: 'Brain exported'},
    'msgBrainImported': {AppLocale.zh: '大脑已导入', AppLocale.en: 'Brain imported'},
    'msgBrainCreated': {
      AppLocale.zh: '已新建大脑（随机初始化）',
      AppLocale.en: 'New brain created (random init)',
    },
    'msgBaseBrainLoaded': {AppLocale.zh: '底座大脑已加载', AppLocale.en: 'Base brain loaded'},
    'msgBaseBrainPlaceholder': {
      AppLocale.zh: '内置底座大脑尚未提供（当前是占位文件），请先新建大脑或导入已有的 .brain',
      AppLocale.en: 'The bundled base brain is not provided yet (placeholder file). Create a new brain or import a .brain first.',
    },
    'msgLoadFailed': {
      AppLocale.zh: '加载大脑失败：文件可能损坏或版本不匹配',
      AppLocale.en: 'Failed to load brain: file may be corrupt or version-mismatched',
    },
    'msgSaveFailed': {AppLocale.zh: '保存大脑失败', AppLocale.en: 'Failed to save brain'},
    'msgInvalidParams': {
      AppLocale.zh: '超参数超出范围，请检查后重试',
      AppLocale.en: 'Hyper-parameters out of range, please check and retry',
    },
    'msgEnterPrompt': {AppLocale.zh: '请先输入 prompt', AppLocale.en: 'Enter a prompt first'},
    'msgNoBrain': {AppLocale.zh: '还没有大脑', AppLocale.en: 'No brain yet'},
    'msgGenFailed': {AppLocale.zh: '生成失败', AppLocale.en: 'Generation failed'},
    'msgCorpusAdded': {AppLocale.zh: '语料已添加', AppLocale.en: 'Corpus added'},
    'msgCorpusEmpty': {AppLocale.zh: '语料不能为空', AppLocale.en: 'Corpus must not be empty'},
    'msgImportFailed': {AppLocale.zh: '导入失败', AppLocale.en: 'Import failed'},
    'msgStructureChange': {
      AppLocale.zh: '结构改变将新建大脑，旧进度会丢失（除非已导出）。确定吗？',
      AppLocale.en: 'Changing the structure creates a new brain and drops current progress (unless exported). Continue?',
    },
  };
}

/// Inherited widget that exposes the current [Strings] to the subtree.
class StringsScope extends InheritedWidget {
  final Strings strings;
  final ValueChanged<AppLocale> onLocaleChanged;

  const StringsScope({
    super.key,
    required this.strings,
    required this.onLocaleChanged,
    required super.child,
  });

  static Strings of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<StringsScope>();
    assert(scope != null, 'StringsScope not found in widget tree');
    return scope!.strings;
  }

  static void setLocale(BuildContext context, AppLocale locale) {
    final scope = context.dependOnInheritedWidgetOfExactType<StringsScope>();
    scope?.onLocaleChanged(locale);
  }

  @override
  bool updateShouldNotify(StringsScope oldWidget) =>
      strings.locale != oldWidget.strings.locale;
}
