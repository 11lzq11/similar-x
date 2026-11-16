/// High-level TDLib client: JSON requests, the authorization state
/// machine, and the chat/message calls the Telegram adapter needs.
///
/// The client speaks TDLib's JSON interface through a [TdlibTransport]
/// (real FFI in production, a fake in tests). Requests carry an `@extra`
/// id; responses are matched back by that id. Authorization is a state
/// machine driven by `updateAuthorizationState` updates:
///
///   waitTdlibParameters -> setTdlibParameters
///   -> waitPhoneNumber -> setAuthenticationPhoneNumber
///   -> waitCode -> checkAuthenticationCode
///   -> waitPassword (only with 2FA) -> checkAuthenticationPassword
///   -> ready
///
/// The database encryption key is passed inside `setTdlibParameters`
/// (`database_encryption_key`, base64) — TDLib 1.8.69 has no
/// `waitEncryptionKey` state and no `checkDatabaseEncryptionKey`
/// function; both were removed in favour of the parameter (verified
/// against the 1.8.69 schema, `td/generate/scheme/td_api.tl`).
/// A restored session jumps straight to `ready`, so login is only
/// needed the first time (or after logout).
library;

import 'dart:async';
import 'dart:convert';

import 'tdlib_transport.dart';
import 'telegram_models.dart';

/// An error returned by TDLib (`@type == 'error'`).
class TdlibException implements Exception {
  TdlibException(this.code, this.message);

  final int code;
  final String message;

  @override
  String toString() => 'TdlibException($code): $message';
}

/// A request got no response within [TdlibClient.defaultTimeout].
class TdlibTimeoutException implements Exception {
  TdlibTimeoutException(this.requestType);

  final String requestType;

  @override
  String toString() => 'TdlibTimeoutException: $requestType timed out';
}

/// TDLib authorization states (from `updateAuthorizationState`).
enum TdlibAuthState {
  unknown,
  waitTdlibParameters,
  waitPhoneNumber,
  waitCode,
  waitOtherDeviceConfirmation,
  waitRegistration,
  waitPassword,
  ready,
  loggingOut,
  closing,
  closed,
}

/// Static configuration for one TDLib client.
///
/// `apiId`/`apiHash` identify the *application* (one per Similar-X
/// install, from my.telegram.org — see the Telegram adapter). They are
/// not the user's login; the user session lives in TDLib's own
/// database under [databaseDirectory], encrypted with [dbEncryptionKey].
class TdlibConfig {
  const TdlibConfig({
    required this.apiId,
    required this.apiHash,
    required this.databaseDirectory,
    required this.filesDirectory,
    this.dbEncryptionKey = '',
    this.applicationVersion = '0.1.0',
    this.deviceModel = 'Similar-X',
    this.systemVersion = '',
    this.languageCode = 'en',
  });

  final int apiId;
  final String apiHash;
  final String databaseDirectory;
  final String filesDirectory;

  /// Key encrypting TDLib's local database. Hex-encoded random bytes,
  /// generated once and kept in secure storage by the adapter. Passed
  /// to TDLib as `database_encryption_key` inside setTdlibParameters
  /// (base64 in the JSON interface). Empty means "no encryption".
  final String dbEncryptionKey;

  final String applicationVersion;
  final String deviceModel;
  final String systemVersion;
  final String languageCode;
}

class TdlibClient {
  TdlibClient({
    required this.transport,
    required this.config,
    this.autoPump = true,
    this.pumpInterval = const Duration(milliseconds: 100),
  });

  static const Duration defaultTimeout = Duration(seconds: 30);

  final TdlibConfig config;

  /// When true (production), a periodic timer pumps updates. Tests pass
  /// false and drive [pump] manually for deterministic behaviour.
  final bool autoPump;

  final Duration pumpInterval;

  /// The transport to TDLib (FFI in production, a fake in tests).
  final TdlibTransport transport;

  int? _clientId;
  int _nextRequestId = 1;
  final Map<int, Completer<Map<String, dynamic>>> _pending = {};
  final StreamController<TdlibAuthState> _authStateController =
      StreamController<TdlibAuthState>.broadcast();
  final StreamController<Map<String, dynamic>> _updatesController =
      StreamController<Map<String, dynamic>>.broadcast();
  Timer? _pumpTimer;
  TdlibAuthState _authState = TdlibAuthState.unknown;
  TelegramAccount? _me;
  final Map<int, String> _userNames = {};
  bool _disposed = false;

  /// Current authorization state.
  TdlibAuthState get authState => _authState;

  /// Broadcast stream of authorization state changes.
  Stream<TdlibAuthState> get authStateStream => _authStateController.stream;

  /// Broadcast stream of non-authorization updates (new messages,
  /// chat updates, ...). Reserved for notifications support.
  Stream<Map<String, dynamic>> get updates => _updatesController.stream;

  bool get isReady => _authState == TdlibAuthState.ready;

  /// Creates the TDLib client and drives the authorization machine up
  /// to `waitPhoneNumber` (fresh login) or `ready` (restored session).
  Future<void> initialize() async {
    if (_clientId != null) return;
    _clientId = transport.create();
    // Keep TDLib quiet: verbosity 1 logs only warnings and errors.
    try {
      transport.execute(_clientId!, jsonEncode(<String, Object?>{
        '@type': 'setLogVerbosityLevel',
        'new_verbosity_level': 1,
      }));
    } catch (_) {
      // Logging level is best-effort; a failure must not block login.
    }
    if (autoPump) {
      _pumpTimer = Timer.periodic(pumpInterval, (_) => pump());
    }
    await _waitForState({TdlibAuthState.waitTdlibParameters});
    await invoke(<String, Object?>{
      '@type': 'setTdlibParameters',
      'use_test_dc': false,
      'database_directory': config.databaseDirectory,
      'files_directory': config.filesDirectory,
      'database_encryption_key': _keyToBase64(config.dbEncryptionKey),
      'use_file_database': true,
      'use_chat_info_database': true,
      'use_message_database': true,
      'use_secret_chats': false,
      'api_id': config.apiId,
      'api_hash': config.apiHash,
      'system_language_code': config.languageCode,
      'device_model': config.deviceModel,
      'system_version': config.systemVersion,
      'application_version': config.applicationVersion,
      'enable_storage_optimizer': true,
      'ignore_background_updates': false,
    });
    await _waitForState({
      TdlibAuthState.waitPhoneNumber,
      TdlibAuthState.waitCode,
      TdlibAuthState.waitPassword,
      TdlibAuthState.ready,
    });
  }

  /// Converts the hex-encoded database key to the base64 string
  /// TDLib's JSON interface expects for `bytes` fields. Non-hex input
  /// is treated as raw UTF-8 bytes (so dev tools can pass a short
  /// passphrase). An empty key encodes to an empty string, which
  /// TDLib reads as "no encryption".
  static String _keyToBase64(String key) {
    final List<int> bytes;
    final bool isHex =
        key.isNotEmpty && key.length.isEven &&
        RegExp(r'^[0-9a-fA-F]+$').hasMatch(key);
    if (isHex) {
      bytes = <int>[
        for (int i = 0; i < key.length; i += 2)
          int.parse(key.substring(i, i + 2), radix: 16),
      ];
    } else {
      bytes = utf8.encode(key);
    }
    return base64Encode(bytes);
  }

  /// Sends the phone number, then waits for the login code state.
  /// Throws [TdlibException] for an invalid number.
  Future<void> submitPhoneNumber(String phoneNumber) async {
    await invoke(<String, Object?>{
      '@type': 'setAuthenticationPhoneNumber',
      'phone_number': phoneNumber,
      'settings': <String, Object?>{
        'allow_flash_call': false,
        'allow_missed_call': false,
        'is_current_phone_number': false,
        'allow_sms_retriever_api': false,
        'authentication_tokens': <String>[],
      },
    });
    await _waitForState({
      TdlibAuthState.waitCode,
      TdlibAuthState.ready,
      TdlibAuthState.waitOtherDeviceConfirmation,
    });
  }

  /// Submits the login code, then waits for `ready` (or the 2FA
  /// password state). Throws [TdlibException] for a wrong/expired code.
  Future<void> submitCode(String code) async {
    await invoke(<String, Object?>{
      '@type': 'checkAuthenticationCode',
      'code': code,
    });
    await _waitForState({
      TdlibAuthState.ready,
      TdlibAuthState.waitPassword,
    });
  }

  /// Submits the 2FA password, then waits for `ready`.
  Future<void> submitPassword(String password) async {
    await invoke(<String, Object?>{
      '@type': 'checkAuthenticationPassword',
      'password': password,
    });
    await _waitForState({TdlibAuthState.ready});
  }

  /// The logged-in account. Cached after the first call.
  Future<TelegramAccount> getMe() async {
    if (_me != null) return _me!;
    final Map<String, dynamic> res = await invoke(<String, Object?>{
      '@type': 'getMe',
    });
    _me = TelegramAccount.fromJson(res);
    return _me!;
  }

  /// The chat list (main list), newest activity first.
  Future<List<TelegramChat>> getChats({int limit = 20}) async {
    final Map<String, dynamic> res = await invoke(<String, Object?>{
      '@type': 'getChats',
      'chat_list': <String, Object?>{'@type': 'chatListMain'},
      'limit': limit,
    });
    final List<dynamic> ids = (res['chat_ids'] as List?) ?? const [];
    final List<TelegramChat> chats = <TelegramChat>[];
    for (final Object? id in ids) {
      final Map<String, dynamic> chatJson = await invoke(<String, Object?>{
        '@type': 'getChat',
        'chat_id': (id as num).toInt(),
      });
      chats.add(TelegramChat.fromJson(chatJson));
    }
    return chats;
  }

  /// Messages of one chat, newest first.
  Future<List<TelegramMessage>> getChatHistory(
    int chatId, {
    int limit = 20,
    int fromMessageId = 0,
  }) async {
    final Map<String, dynamic> res = await invoke(<String, Object?>{
      '@type': 'getChatHistory',
      'chat_id': chatId,
      'from_message_id': fromMessageId,
      'offset': 0,
      'limit': limit,
      'only_local': false,
    });
    final List<dynamic> raw = (res['messages'] as List?) ?? const [];
    final TelegramAccount me = await getMe();
    final List<TelegramMessage> messages = <TelegramMessage>[];
    for (final Object? item in raw) {
      if (item is! Map<String, dynamic>) continue;
      messages.add(await _mapMessage(item, myUserId: me.userId));
    }
    return messages;
  }

  /// Sends a text message to a chat and returns the sent message.
  Future<TelegramMessage> sendMessage(int chatId, String text) async {
    final Map<String, dynamic> res = await invoke(<String, Object?>{
      '@type': 'sendMessage',
      'chat_id': chatId,
      'reply_to': null,
      'options': <String, Object?>{
        'disable_notification': false,
        'from_background': false,
        'protect_content': false,
        'update_order_of_installed_sticker_sets': false,
        'scheduling_state': null,
      },
      'reply_markup': null,
      'input_message_content': <String, Object?>{
        '@type': 'inputMessageText',
        'text': <String, Object?>{
          '@type': 'formattedText',
          'text': text,
          'entities': <Object?>[],
        },
        'link_preview_options': null,
        'clear_draft': false,
      },
    });
    return TelegramMessage.fromJson(res, senderName: 'You');
  }

  /// Logs out: the session and the local TDLib database are deleted.
  /// The client must be re-created (via [initialize]) to log in again.
  Future<void> logOut() async {
    if (_clientId == null) return;
    await invoke(<String, Object?>{'@type': 'logOut'});
    await _waitForState({TdlibAuthState.closed});
    _destroyClient();
  }

  /// Processes one pending update (one `receive` call). Called by the
  /// internal timer in production; tests call it directly.
  void pump() {
    final int? id = _clientId;
    if (id == null || _disposed) return;
    final String? raw = transport.receive(id, 0.0);
    if (raw == null) return;
    final Object? decoded = jsonDecode(raw);
    if (decoded is Map<String, dynamic>) _dispatch(decoded);
  }

  /// Sends a request and completes with the matching response.
  /// Throws [TdlibException] when TDLib answers with an error object,
  /// [TdlibTimeoutException] when no answer arrives in time.
  Future<Map<String, dynamic>> invoke(
    Map<String, dynamic> request, {
    Duration timeout = defaultTimeout,
  }) async {
    final int? id = _clientId;
    if (id == null) {
      throw StateError('TdlibClient is not initialized; call initialize() first.');
    }
    final int requestId = _nextRequestId++;
    final Completer<Map<String, dynamic>> completer =
        Completer<Map<String, dynamic>>();
    _pending[requestId] = completer;
    final Map<String, dynamic> withExtra = Map<String, dynamic>.of(request)
      ..['@extra'] = requestId;
    transport.send(id, jsonEncode(withExtra));
    // Local timer per request: several invokes may be in flight at once
    // (e.g. getChats fans out to getChat), so this must not be a field.
    final Timer timeoutTimer = Timer(timeout, () {
      final Completer<Map<String, dynamic>>? pending =
          _pending.remove(requestId);
      if (pending != null && !pending.isCompleted) {
        pending.completeError(
          TdlibTimeoutException((request['@type'] as String?) ?? 'request'),
        );
      }
    });
    try {
      return await completer.future;
    } finally {
      timeoutTimer.cancel();
    }
  }

  Future<void> _waitForState(
    Set<TdlibAuthState> states, {
    Duration timeout = defaultTimeout,
  }) async {
    if (states.contains(_authState)) return;
    final Completer<void> completer = Completer<void>();
    late final StreamSubscription<TdlibAuthState> sub;
    sub = _authStateController.stream.listen((TdlibAuthState state) {
      if (states.contains(state) && !completer.isCompleted) {
        completer.complete();
      }
    });
    try {
      await completer.future.timeout(timeout, onTimeout: () {
        throw TdlibTimeoutException(
          'waiting for ${states.map((s) => s.name).join('/')} '
          '(current: ${_authState.name})',
        );
      });
    } finally {
      await sub.cancel();
    }
  }

  void _dispatch(Map<String, dynamic> update) {
    final String type = (update['@type'] as String?) ?? '';
    if (type == 'updateAuthorizationState') {
      final Map<String, dynamic>? stateJson =
          update['authorization_state'] as Map<String, dynamic>?;
      _setAuthState(_parseAuthState(
        (stateJson?['@type'] as String?) ?? '',
      ));
      return;
    }
    final Object? extra = update['@extra'];
    if (extra is int && _pending.containsKey(extra)) {
      final Completer<Map<String, dynamic>> completer =
          _pending.remove(extra)!;
      if (type == 'error') {
        completer.completeError(
          TdlibException(
            (update['code'] as num?)?.toInt() ?? 0,
            (update['message'] as String?) ?? 'unknown error',
          ),
        );
      } else {
        completer.complete(update);
      }
      return;
    }
    if (!_updatesController.isClosed) _updatesController.add(update);
  }

  void _setAuthState(TdlibAuthState state) {
    _authState = state;
    if (!_authStateController.isClosed) {
      _authStateController.add(state);
    }
  }

  static TdlibAuthState _parseAuthState(String raw) => switch (raw) {
        'authorizationStateWaitTdlibParameters' =>
          TdlibAuthState.waitTdlibParameters,
        'authorizationStateWaitPhoneNumber' =>
          TdlibAuthState.waitPhoneNumber,
        'authorizationStateWaitCode' => TdlibAuthState.waitCode,
        'authorizationStateWaitOtherDeviceConfirmation' =>
          TdlibAuthState.waitOtherDeviceConfirmation,
        'authorizationStateWaitRegistration' =>
          TdlibAuthState.waitRegistration,
        'authorizationStateWaitPassword' => TdlibAuthState.waitPassword,
        'authorizationStateReady' => TdlibAuthState.ready,
        'authorizationStateLoggingOut' => TdlibAuthState.loggingOut,
        'authorizationStateClosing' => TdlibAuthState.closing,
        'authorizationStateClosed' => TdlibAuthState.closed,
        _ => TdlibAuthState.unknown,
      };

  Future<TelegramMessage> _mapMessage(
    Map<String, dynamic> json, {
    required int myUserId,
  }) async {
    final Map<String, dynamic>? senderJson =
        json['sender_id'] as Map<String, dynamic>?;
    final String senderType = (senderJson?['@type'] as String?) ?? '';
    String senderName;
    if (senderType == 'messageSenderChat') {
      senderName = 'Channel';
    } else {
      final int senderId = (senderJson?['user_id'] as num?)?.toInt() ?? 0;
      senderName = senderId == myUserId ? 'You' : await _userName(senderId);
    }
    return TelegramMessage.fromJson(json, senderName: senderName);
  }

  Future<String> _userName(int userId) async {
    if (userId == 0) return '';
    final String? cached = _userNames[userId];
    if (cached != null) return cached;
    try {
      final Map<String, dynamic> res = await invoke(<String, Object?>{
        '@type': 'getUser',
        'user_id': userId,
      });
      final String firstName = (res['first_name'] as String?) ?? '';
      final String lastName = (res['last_name'] as String?) ?? '';
      final String name = [firstName, lastName]
          .where((s) => s.isNotEmpty)
          .join(' ');
      final String resolved = name.isEmpty ? 'User $userId' : name;
      _userNames[userId] = resolved;
      return resolved;
    } on TdlibException {
      return 'User $userId';
    }
  }

  void _destroyClient() {
    final int? id = _clientId;
    _clientId = null;
    _me = null;
    _userNames.clear();
    if (id != null) transport.destroy(id);
  }

  /// Stops the pump timer, destroys the TDLib client and closes the
  /// streams. The adapter calls this on logout and on dispose.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _pumpTimer?.cancel();
    for (final Completer<Map<String, dynamic>> c in _pending.values) {
      if (!c.isCompleted) {
        c.completeError(StateError('TdlibClient disposed'));
      }
    }
    _pending.clear();
    _destroyClient();
    _authStateController.close();
    _updatesController.close();
  }
}
