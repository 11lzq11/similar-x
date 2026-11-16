// ignore_for_file: avoid_print
// Dev tool: verify the real TDLib FFI layer loads and answers.
//
// Run after fetching the native library for your platform:
//   python3 scripts/fetch_tdlib.py --platform linux   # or android/ios/...
//   dart tool/verify_tdlib.dart
//
// It uses dummy API credentials and only drives TDLib as far as the
// phone-number step (no login, no network login attempt is needed for
// that state). It proves the FFI transport, the JSON client and the
// native library all work together. Requires the library to be on the
// loader path (Linux: LD_LIBRARY_PATH=linux).
import 'dart:async';
import 'dart:io' show Directory;

import 'package:similar_x/adapters/telegram/tdlib_client.dart';
import 'package:similar_x/adapters/telegram/tdlib_transport.dart';

Future<void> main() async {
  final Directory tmp = await Directory.systemTemp.createTemp('tdlib-verify-');
  final TdlibClient client = TdlibClient(
    transport: FfiTdlibTransport(),
    config: TdlibConfig(
      apiId: 12345,
      apiHash: 'testhash',
      databaseDirectory: '${tmp.path}/db',
      filesDirectory: '${tmp.path}/files',
      dbEncryptionKey: 'verify',
    ),
  );
  try {
    await client.initialize().timeout(const Duration(seconds: 60));
    print('auth state: ${client.authState}');
    if (client.authState != TdlibAuthState.waitPhoneNumber) {
      throw StateError('expected waitPhoneNumber, got ${client.authState}');
    }
    final Map<String, dynamic> version = await client
        .invoke(<String, Object?>{'@type': 'getOption', 'name': 'version'})
        .timeout(const Duration(seconds: 30));
    print('TDLib version: ${version['value']}');
    print('VERIFY OK');
  } finally {
    client.dispose();
    await tmp.delete(recursive: true);
  }
}
