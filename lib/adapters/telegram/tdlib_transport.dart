/// Transport layer for TDLib's C JSON interface (`td_json_client_*`).
///
/// TDLib speaks JSON: every function returns a JSON object with an
/// `@type` field. This file is the only place that touches `dart:ffi` —
/// everything above it speaks JSON maps, which is what makes the
/// adapter unit-testable with a fake transport (see
/// `test/telegram_adapter_test.dart`).
///
/// Why a hand-written FFI layer instead of a pub.dev TDLib package?
/// Checked 2026-11-16: `libtdjson` covers Android/iOS/macOS only (no
/// Windows/Linux) and its Android build needs GitHub Packages auth;
/// `handy_tdlib_next` ships prebuilt libraries for Android only;
/// `tdlib_ex` ships no native binaries at all. Similar-X targets five
/// platforms, so the transport is ours and the native library is a
/// pinned prebuilt artifact downloaded at build time by
/// `scripts/fetch_tdlib.py` (Mithka's `mithka-tdjson` releases, TDLib
/// 1.8.69, SHA-256 verified, never committed to the repo).
///
/// TDLib has TWO C APIs — do not mix them up (doing so segfaults):
/// * `td_json_client_*` — the handle is an opaque `void *`
///   (`ClientJson *`); `create` returns it, the rest take it.
/// * `td_*` (`td_create_client_id`, `td_send`, `td_receive`,
///   `td_execute`) — the handle is a small `int`, and `receive` /
///   `execute` take no handle at all.
/// This transport uses `td_json_client_*`. The Dart side keeps the
/// small-`int` handle (so the fake transport and the client stay
/// simple) and maps it to the native pointer internally.
library;

import 'dart:ffi' as ffi;
import 'dart:io' show File, Platform;

import 'package:ffi/ffi.dart';

/// Thrown when the native `libtdjson` library cannot be loaded or a
/// required symbol is missing. Usually means the platform build did
/// not fetch the native library (see `scripts/fetch_tdlib.py`).
class TdlibLibraryException implements Exception {
  TdlibLibraryException(this.message);

  final String message;

  @override
  String toString() => 'TdlibLibraryException: $message';
}

/// The five functions of TDLib's JSON interface. Any implementation
/// must be safe to call from the client's receive pump.
abstract class TdlibTransport {
  /// Creates a TDLib client and returns its id.
  int create();

  /// Sends a JSON-encoded request to [clientId].
  void send(int clientId, String requestJson);

  /// Receives the next JSON-encoded update, waiting at most
  /// [timeoutSeconds]. Returns null on timeout.
  String? receive(int clientId, double timeoutSeconds);

  /// Executes a JSON-encoded request synchronously and returns the
  /// JSON-encoded result (used for `getOption` and friends).
  String? execute(int clientId, String requestJson);

  /// Destroys the TDLib client.
  void destroy(int clientId);
}

/// FFI implementation of [TdlibTransport] over the platform's
/// `libtdjson`.
///
/// Library lookup, in order:
/// * iOS: the linked `tdjson` framework — symbols live in the process.
/// * macOS: the embedded `libtdjson.dylib` inside the app bundle
///   (`Contents/Frameworks/libtdjson.dylib`), falling back to the
///   process image and then to `libtdjson.dylib` on the loader path.
/// * Windows: `tdjson.dll` next to the executable.
/// * Android/Linux: `libtdjson.so` (Android `jniLibs`, Linux bundle
///   `lib/` — both are on the loader path at runtime).
///
/// The native `td_json_client_*` handle is an opaque pointer. This
/// class hands out small `int` ids instead and keeps the
/// id -> pointer map here, so callers never see a raw pointer.
class FfiTdlibTransport implements TdlibTransport {
  FfiTdlibTransport() {
    final ffi.DynamicLibrary lib = _loadLibrary();
    _create = lib.lookupFunction<_TdCreateNative, _TdCreate>(
      'td_json_client_create',
    );
    _send = lib.lookupFunction<_TdSendNative, _TdSend>(
      'td_json_client_send',
    );
    _receive = lib.lookupFunction<_TdReceiveNative, _TdReceive>(
      'td_json_client_receive',
    );
    _execute = lib.lookupFunction<_TdExecuteNative, _TdExecute>(
      'td_json_client_execute',
    );
    _destroy = lib.lookupFunction<_TdDestroyNative, _TdDestroy>(
      'td_json_client_destroy',
    );
  }

  late final _TdCreate _create;
  late final _TdSend _send;
  late final _TdReceive _receive;
  late final _TdExecute _execute;
  late final _TdDestroy _destroy;

  final Map<int, ffi.Pointer<ffi.Void>> _clients =
      <int, ffi.Pointer<ffi.Void>>{};
  int _nextId = 1;

  static ffi.DynamicLibrary _loadLibrary() {
    try {
      if (Platform.isIOS) {
        return ffi.DynamicLibrary.process();
      }
      if (Platform.isMacOS) {
        // <App>.app/Contents/MacOS/<exe> -> <App>.app/Contents/Frameworks/
        // The library is embedded there either as a bare dylib
        // (libtdjson.dylib, from scripts/fetch_tdlib.py) or as a
        // framework (tdjson.framework/tdjson).
        final String contentsDir = File(Platform.resolvedExecutable)
            .parent
            .parent
            .path;
        for (final String candidate in <String>[
          '$contentsDir/Frameworks/libtdjson.dylib',
          '$contentsDir/Frameworks/tdjson.framework/tdjson',
        ]) {
          if (File(candidate).existsSync()) {
            return ffi.DynamicLibrary.open(candidate);
          }
        }
        try {
          return ffi.DynamicLibrary.open('libtdjson.dylib');
        } on ArgumentError {
          // Last resort: the library is linked into the process.
          return ffi.DynamicLibrary.process();
        }
      }
      if (Platform.isWindows) {
        return ffi.DynamicLibrary.open('tdjson.dll');
      }
      // Linux: the library lives in the bundle's lib/ directory next
      // to the executable (installed there by linux/CMakeLists.txt,
      // found via the executable's $ORIGIN/lib RPATH). Try that
      // location first, then the plain name (LD_LIBRARY_PATH / dev).
      final String exeDir = File(Platform.resolvedExecutable).parent.path;
      final String bundled = '$exeDir/lib/libtdjson.so';
      if (File(bundled).existsSync()) {
        return ffi.DynamicLibrary.open(bundled);
      }
      return ffi.DynamicLibrary.open('libtdjson.so');
    } on ArgumentError catch (e) {
      throw TdlibLibraryException(
        'could not load libtdjson: $e. '
        'Run scripts/fetch_tdlib.py for your platform first.',
      );
    }
  }

  ffi.Pointer<ffi.Void> _pointer(int clientId) {
    final ffi.Pointer<ffi.Void>? ptr = _clients[clientId];
    if (ptr == null) {
      throw StateError('unknown TDLib client id $clientId');
    }
    return ptr;
  }

  @override
  int create() {
    final ffi.Pointer<ffi.Void> ptr = _create();
    final int id = _nextId++;
    _clients[id] = ptr;
    return id;
  }

  @override
  void send(int clientId, String requestJson) {
    final ffi.Pointer<Utf8> native = requestJson.toNativeUtf8();
    try {
      _send(_pointer(clientId), native);
    } finally {
      calloc.free(native);
    }
  }

  @override
  String? receive(int clientId, double timeoutSeconds) {
    final ffi.Pointer<Utf8> ptr =
        _receive(_pointer(clientId), timeoutSeconds);
    // TDLib owns the returned string; copy it now, never free it.
    if (ptr.address == 0) return null;
    return ptr.toDartString();
  }

  @override
  String? execute(int clientId, String requestJson) {
    final ffi.Pointer<Utf8> native = requestJson.toNativeUtf8();
    try {
      final ffi.Pointer<Utf8> ptr = _execute(_pointer(clientId), native);
      if (ptr.address == 0) return null;
      return ptr.toDartString();
    } finally {
      calloc.free(native);
    }
  }

  @override
  void destroy(int clientId) {
    final ffi.Pointer<ffi.Void>? ptr = _clients.remove(clientId);
    if (ptr != null) _destroy(ptr);
  }
}

typedef _TdCreateNative = ffi.Pointer<ffi.Void> Function();
typedef _TdCreate = ffi.Pointer<ffi.Void> Function();
typedef _TdSendNative = ffi.Void Function(
  ffi.Pointer<ffi.Void>,
  ffi.Pointer<Utf8>,
);
typedef _TdSend = void Function(
  ffi.Pointer<ffi.Void>,
  ffi.Pointer<Utf8>,
);
typedef _TdReceiveNative = ffi.Pointer<Utf8> Function(
  ffi.Pointer<ffi.Void>,
  ffi.Double,
);
typedef _TdReceive = ffi.Pointer<Utf8> Function(
  ffi.Pointer<ffi.Void>,
  double,
);
typedef _TdExecuteNative = ffi.Pointer<Utf8> Function(
  ffi.Pointer<ffi.Void>,
  ffi.Pointer<Utf8>,
);
typedef _TdExecute = ffi.Pointer<Utf8> Function(
  ffi.Pointer<ffi.Void>,
  ffi.Pointer<Utf8>,
);
typedef _TdDestroyNative = ffi.Void Function(ffi.Pointer<ffi.Void>);
typedef _TdDestroy = void Function(ffi.Pointer<ffi.Void>);
