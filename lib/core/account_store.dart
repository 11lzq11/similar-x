import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Encrypted on-device storage for per-platform account tokens.
///
/// Design rules (see research/third-party-feasibility.md):
/// * one token per platform, keyed by the adapter id;
/// * tokens are stored with the OS keystore/keychain and never leave the
///   device — Similar-X has no backend, so there is nowhere to send them;
/// * each platform gets the smallest OAuth scope that still works.
class AccountStore {
  AccountStore({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  String _key(String platformId) => 'similar_x_token_$platformId';

  Future<void> saveToken(String platformId, String token) =>
      _storage.write(key: _key(platformId), value: token);

  Future<String?> readToken(String platformId) =>
      _storage.read(key: _key(platformId));

  Future<void> deleteToken(String platformId) =>
      _storage.delete(key: _key(platformId));

  Future<bool> hasToken(String platformId) async =>
      await readToken(platformId) != null;

  /// Deletes every stored token (log out of everything).
  Future<void> deleteAll() => _storage.deleteAll();

  /// Generic encrypted key/value storage for per-platform settings that
  /// are not OAuth tokens — e.g. Telegram's api_id/api_hash and its
  /// database encryption key. Same encrypted storage, same rules: the
  /// value never leaves the device.
  Future<void> saveValue(String key, String value) =>
      _storage.write(key: key, value: value);

  Future<String?> readValue(String key) => _storage.read(key: key);

  Future<void> deleteValue(String key) => _storage.delete(key: key);
}
