// Engine — the abstract interface the app programs against. The real
// implementation is [TinyTrainerEngine] (dart:ffi, native C engine); tests
// use a fake that implements this interface, so the app logic never depends
// on the native library being present.
abstract class Engine {
  /// Total parameter count for the current structure.
  int get paramCount;

  /// Current vocabulary size (0 until a corpus is set).
  int get vocabSize;

  /// Current training step.
  int get step;

  /// Most recent loss (NaN if no step has run yet).
  double get loss;

  /// Total tokens in the current corpus.
  int get corpusTokens;

  /// Whether this engine has been disposed.
  bool get isDisposed;

  /// Live-tunable: peak learning rate / batch size (take effect immediately).
  void setLr(double lr);
  void setBatchSize(int batch);

  /// Set the corpus text. First call builds the vocabulary; later calls
  /// only swap the corpus. Returns false on empty/invalid text.
  bool setCorpus(String text);

  /// Train [steps] steps. Blocking — call from a background isolate or a
  /// worker. Returns one average cross-entropy loss per step.
  List<double> trainSteps(int steps);

  /// Generate text from [prompt]. Returns the continuation (without the
  /// prompt) or '' on failure.
  String generate(
    String prompt, {
    int maxTokens = 64,
    double temperature = 0.8,
    int topK = 40,
    int seed = 0,
  });

  /// Save the brain to [path] (a .brain file). Returns false on failure.
  bool saveBrain(String path);

  /// Free the native model. Idempotent.
  void dispose();
}
