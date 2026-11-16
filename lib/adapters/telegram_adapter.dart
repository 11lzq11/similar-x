import 'dart:io' show Directory;
import 'dart:math' show Random;

import 'package:path_provider/path_provider.dart';

import '../core/account_store.dart';
import '../core/platform_adapter.dart';
import 'telegram/tdlib_client.dart';
import 'telegram/tdlib_transport.dart';
import 'telegram/telegram_models.dart';

/// Thrown when the user has not entered their Telegram API credentials
/// yet. The credentials come from https://my.telegram.org (free, no
/// approval): create an app there and copy the `api_id` (number) and
/// `api_hash` (string) into Similar-X settings.
class TelegramCredentialsMissingException implements Exception {
  @override
  String toString() =>
      'TelegramCredentialsMissingException: no Telegram API credentials. '
      'Get api_id and api_hash at https://my.telegram.org and save them '
      'in Similar-X settings, then log in.';
}

/// Thrown when a Telegram action needs a logged-in account.
class TelegramNotLoggedInException implements Exception {
  @override
  String toString() =>
      'TelegramNotLoggedInException: log in to Telegram first.';
}

/// Telegram — tier 1, fully feasible.
///
/// Official MTProto API + TDLib, free, no approval, no quota. The
/// adapter talks to TDLib's JSON interface through [TdlibClient]
/// (FFI in production, a fake in tests). The user brings their own
/// `api_id`/`api_hash` from my.telegram.org — they identify the
/// *application*, are stored encrypted on-device, and are never sent
/// anywhere except to Telegram. The user session lives in TDLib's own
/// database (app documents directory), encrypted with a random key
/// that is also kept in secure storage.
///
/// Status is `limited`, not `ready`: login, chats, messages and
/// sending work; reactions and notifications are not implemented yet.
class TelegramAdapter extends PlatformAdapter {
  TelegramAdapter({TdlibClient? client, AccountStore? accountStore}) {
    _client = client;
    _accountStore = accountStore ?? AccountStore();
  }

  static const String _apiIdKey = 'telegram_api_id';
  static const String _apiHashKey = 'telegram_api_hash';
  static const String _dbKeyKey = 'telegram_db_key';

  late final AccountStore _accountStore;
  TdlibClient? _client;

  /// True when [_client] was created by [_ensureClient] (so the
  /// adapter owns it and may dispose it). An injected client belongs
  /// to its creator.
  bool _ownsClient = false;

  @override
  String get id => 'telegram';

  @override
  String get displayName => 'Telegram';

  @override
  PlatformStatus get status => PlatformStatus.limited;

  @override
  Set<AdapterCapability> get capabilities => const <AdapterCapability>{
        AdapterCapability.timeline,
        AdapterCapability.post,
        AdapterCapability.directMessage,
      };

  @override
  String get note =>
      'Login, chats and messages work via TDLib; reactions and '
      'notifications are next. Needs your own api_id/api_hash from '
      'my.telegram.org.';

  @override
  bool get requiresLogin => true;

  /// Whether the user has saved their Telegram API credentials.
  /// Secure-storage errors count as "not configured" — the UI then
  /// shows the credentials form instead of crashing.
  Future<bool> get credentialsConfigured async {
    try {
      final String? apiId = await _accountStore.readValue(_apiIdKey);
      final String? apiHash = await _accountStore.readValue(_apiHashKey);
      return apiId != null &&
          apiId.isNotEmpty &&
          apiHash != null &&
          apiHash.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  /// Saves the user's Telegram API credentials (from my.telegram.org)
  /// encrypted on-device. A client the adapter created is dropped so
  /// the next login uses the new credentials; an injected client
  /// (tests) is left alone — the test owns it.
  Future<void> saveCredentials({
    required int apiId,
    required String apiHash,
  }) async {
    if (_ownsClient) {
      _client?.dispose();
    }
    _client = null;
    _ownsClient = false;
    await _accountStore.saveValue(_apiIdKey, apiId.toString());
    await _accountStore.saveValue(_apiHashKey, apiHash);
  }

  /// Current authorization state (phone number, code, password, ready,
  /// ...). The UI drives the login flow from this stream.
  Stream<TdlibAuthState> get authState {
    final TdlibClient? client = _client;
    if (client == null) return const Stream<TdlibAuthState>.empty();
    return client.authStateStream;
  }

  @override
  Future<bool> get isLoggedIn async {
    try {
      if (!await credentialsConfigured) return false;
      final TdlibClient client = await _ensureClient();
      return client.isReady;
    } catch (_) {
      // A missing native library or a broken session counts as
      // logged out; the login flow surfaces the real error.
      return false;
    }
  }

  /// The unified timeline: the chat list, each chat represented by its
  /// last message. Empty for guests — Telegram has no public timeline
  /// without an account.
  @override
  Future<List<Post>> fetchTimeline({int limit = 20}) async {
    if (!await isLoggedIn) return const <Post>[];
    final List<TelegramChat> chats = await _client!.getChats(limit: limit);
    return chats
        .map(
          (TelegramChat chat) => Post(
            id: 'telegram:${chat.id}',
            platformId: id,
            authorName: chat.title,
            authorHandle: chat.type,
            text: chat.lastMessage?.text ?? '',
            createdAt: chat.lastMessage?.date ?? DateTime.now(),
          ),
        )
        .toList();
  }

  /// Starts the login flow: initializes TDLib (restores the session
  /// when one exists) and stops at the phone-number step for a fresh
  /// login. The UI then calls [submitPhoneNumber], [submitCode] and
  /// (with 2FA) [submitPassword]. Throws
  /// [TelegramCredentialsMissingException] when no API credentials
  /// have been saved yet.
  @override
  Future<void> login() async {
    await _ensureClient();
  }

  /// Submits the phone number (international format, e.g. +8613800...).
  Future<void> submitPhoneNumber(String phoneNumber) async {
    final TdlibClient client = await _ensureClient();
    await client.submitPhoneNumber(phoneNumber);
  }

  /// Submits the login code Telegram sent (SMS / in-app / call).
  Future<void> submitCode(String code) async {
    final TdlibClient client = await _ensureClient();
    await client.submitCode(code);
  }

  /// Submits the two-step verification password (only when 2FA is on).
  Future<void> submitPassword(String password) async {
    final TdlibClient client = await _ensureClient();
    await client.submitPassword(password);
  }

  /// The logged-in account, or null when logged out.
  Future<TelegramAccount?> get account async {
    if (!await isLoggedIn) return null;
    return _client!.getMe();
  }

  /// The chat list (main list), newest activity first.
  Future<List<TelegramChat>> fetchChats({int limit = 20}) async {
    if (!await isLoggedIn) throw TelegramNotLoggedInException();
    return _client!.getChats(limit: limit);
  }

  /// Messages of one chat, newest first.
  Future<List<TelegramMessage>> fetchMessages(
    int chatId, {
    int limit = 20,
  }) async {
    if (!await isLoggedIn) throw TelegramNotLoggedInException();
    return _client!.getChatHistory(chatId, limit: limit);
  }

  /// Sends a text message to a chat.
  Future<TelegramMessage> sendMessage(int chatId, String text) async {
    if (!await isLoggedIn) throw TelegramNotLoggedInException();
    return _client!.sendMessage(chatId, text);
  }

  /// Logs out: the session is revoked on Telegram's side, the local
  /// TDLib database is deleted, and the database encryption key is
  /// forgotten. The API credentials are kept so the user does not have
  /// to re-enter them.
  @override
  Future<void> logout() async {
    final TdlibClient? client = _client;
    _client = null;
    try {
      if (client != null && client.isReady) {
        await client.logOut();
      }
    } catch (_) {
      // Server-side logout is best-effort; local cleanup below is
      // what actually signs the user out of this device.
    } finally {
      client?.dispose();
    }
    await _accountStore.deleteValue(_dbKeyKey);
    await _deleteDatabaseDirectory();
  }

  Future<TdlibClient> _ensureClient() async {
    final TdlibClient? existing = _client;
    if (existing != null) {
      // An injected client (tests) still needs initialize().
      await existing.initialize();
      return existing;
    }
    final String? apiIdRaw = await _accountStore.readValue(_apiIdKey);
    final String? apiHash = await _accountStore.readValue(_apiHashKey);
    final int? apiId = int.tryParse(apiIdRaw ?? '');
    if (apiId == null || apiHash == null || apiHash.isEmpty) {
      throw TelegramCredentialsMissingException();
    }
    final Directory appDir = await getApplicationDocumentsDirectory();
    final Directory tdlibDir = Directory('${appDir.path}/tdlib');
    await tdlibDir.create(recursive: true);
    final TdlibClient client = TdlibClient(
      transport: FfiTdlibTransport(),
      config: TdlibConfig(
        apiId: apiId,
        apiHash: apiHash,
        databaseDirectory: tdlibDir.path,
        filesDirectory: '${tdlibDir.path}/files',
        dbEncryptionKey: await _ensureDbKey(),
      ),
    );
    _client = client;
    _ownsClient = true;
    await client.initialize();
    return client;
  }

  /// The key encrypting TDLib's local database: 32 random bytes,
  /// hex-encoded, generated once and kept in secure storage.
  Future<String> _ensureDbKey() async {
    final String? existing = await _accountStore.readValue(_dbKeyKey);
    if (existing != null && existing.isNotEmpty) return existing;
    final Random random = Random.secure();
    final List<int> bytes =
        List<int>.generate(32, (_) => random.nextInt(256));
    final String key = bytes
        .map((int b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    await _accountStore.saveValue(_dbKeyKey, key);
    return key;
  }

  Future<void> _deleteDatabaseDirectory() async {
    try {
      final Directory appDir = await getApplicationDocumentsDirectory();
      final Directory tdlibDir = Directory('${appDir.path}/tdlib');
      if (await tdlibDir.exists()) {
        await tdlibDir.delete(recursive: true);
      }
    } catch (_) {
      // Cleanup is best-effort; a leftover directory is harmless.
    }
  }
}
