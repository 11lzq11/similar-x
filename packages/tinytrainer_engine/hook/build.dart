// Build hook: compile the TinyTrainer C engine (src/tinygpt.c) into a
// native library for the target platform, using package:native_toolchain_c.
//
// OpenMP is platform/compiler specific, so the flags are chosen per target:
//   - Android (NDK Clang): -fopenmp -static-openmp. The -fopenmp must be
//     present at LINK time too (it is what makes Clang link libomp at all;
//     -static-openmp alone leaves __kmpc_* undefined — this broke CI for
//     the native Android app). -static-openmp avoids a libomp.so runtime
//     dependency.
//   - Linux (GCC/Clang): -fopenmp (links libgomp).
//   - Windows (MSVC): /openmp.
//   - iOS / macOS (Apple Clang): no OpenMP support — no flag. The engine's
//     #pragma omp directives are ignored and it degrades to serial. Still
//     correct, just slower on Apple devices.
import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:logging/logging.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    final packageName = input.packageName;
    final targetOS = input.config.code.targetOS;

    final List<String> ompFlags;
    switch (targetOS) {
      case OS.android:
        ompFlags = ['-fopenmp', '-static-openmp'];
      case OS.linux:
        // Dynamic OpenMP only. -static-openmp is Clang-only (GCC rejects
        // it; GCC wants -static-libgomp) and the CI/local compiler varies,
        // so do not force static linking here. libgomp/libomp is part of
        // the standard C runtime on Linux desktops, so the .so loads fine.
        ompFlags = ['-fopenmp'];
      case OS.windows:
        ompFlags = ['/openmp'];
      case OS.iOS:
      case OS.macOS:
        // Apple Clang has no OpenMP runtime; serial fallback.
        ompFlags = [];
      default:
        ompFlags = [];
    }

    final cbuilder = CBuilder.library(
      name: packageName,
      assetName: 'tinytrainer_engine_bindings_generated.dart',
      sources: ['src/tinygpt.c'],
      // flags are passed to both the compile and the link step.
      flags: ['-O2', '-Wall', '-Wextra', ...ompFlags],
      language: Language.c,
      std: 'c99',
    );
    await cbuilder.run(
      input: input,
      output: output,
      logger: Logger('')
        ..level = Level.ALL
        // ignore: avoid_print
        ..onRecord.listen((record) => print(record.message)),
    );
  });
}
