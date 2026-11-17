// Public API of the tinytrainer_engine package.
//
// The C engine is compiled from src/tinygpt.c by hook/build.dart and linked
// automatically (native assets). The app programs against the [Engine]
// interface; [TinyTrainerEngine] is the real FFI implementation.
export 'src/config.dart';
export 'src/engine.dart';
export 'src/ffi_engine.dart';
