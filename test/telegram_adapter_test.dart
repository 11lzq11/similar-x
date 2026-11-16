// Telegram adapter tests, driven by a scripted fake TDLib.
//
// No real Telegram account, network or native library is involved:
// [FakeTdlibTransport] answers TDLib JSON requests with canned data
// and plays the authorization state machine (parameters -> encryption
// key -> phone number -> code -> ready). The client's receive pump is
// driven manually via [drive] because tests run with autoPump off.

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:similar_x/adapters/telegram/tdlib_client.dart';
import 'package:similar_x/adapters/telegram/tdlib_transport.dart';
import 'package:similar_x/adapters/telegram/telegram_models.dart';
import 'package:similar_x/adapters/telegram_adapter.dart';
import 'package:similar_x/core/account_store.dart';
import 'package:similar_x/core/platform_adapter.dart';

/// A TDLib that never touches the network. It records every request
/// and answers from canned JSON, playing the auth state machine as
/// real TDLib 1.8.69 does: setTdlibParameters (carrying
/// database_encryption_key) -> WaitPhoneNumber,
/// setAuthenticationPhoneNumber -> WaitCode (only for a plausible
/// `+...` number), checkAuthenticationCode('12345') -> Ready.
class FakeTdlibTransport implements TdlibTransport {
  FakeTdlibTransport() {
    _updates.add(_authUpdate('authorizationStateWaitTdlibParameters'));
  }

  final List<String> sentRequests = <String>[];
  final List<String> _updates = <String>[];

  bool get hasPendingUpdates => _updates.isNotEmpty;

  int _nextClientId = 1;

  @override
  int create() => _nextClientId++;

  @override
  void send(int clientId, String requestJson) {
    sentRequests.add(requestJson);
    final Map<String, dynamic> req =
        jsonDecode(requestJson) as Map<String, dynamic>;
    final String type = (req['@type'] as String?) ?? '';
    final Object? extra = req['@extra'];
    switch (type) {
      case 'setTdlibParameters':
        // The database key must ride along in setTdlibParameters
        // (TDLib 1.8.69 has no separate key step).
        assert(
          (req['database_encryption_key'] as String?)?.isNotEmpty == true,
          'setTdlibParameters must carry database_encryption_key',
        );
        _respond(extra, <String, Object?>{'@type': 'ok'});
        _updates.add(_authUpdate('authorizationStateWaitPhoneNumber'));
      case 'setAuthenticationPhoneNumber':
        final String phone = (req['phone_number'] as String?) ?? '';
        if (phone.startsWith('+') && phone.length > 6) {
          _respond(extra, <String, Object?>{'@type': 'ok'});
          _updates.add(_authUpdate('authorizationStateWaitCode'));
        } else {
          _respondError(extra, 400, 'PHONE_NUMBER_INVALID');
        }
      case 'checkAuthenticationCode':
        if ((req['code'] as String?) == '12345') {
          _respond(extra, <String, Object?>{'@type': 'ok'});
          _updates.add(_authUpdate('authorizationStateReady'));
        } else {
          _respondError(extra, 400, 'PHONE_CODE_INVALID');
        }
      case 'checkAuthenticationPassword':
        if ((req['password'] as String?) == 'secret2fa') {
          _respond(extra, <String, Object?>{'@type': 'ok'});
          _updates.add(_authUpdate('authorizationStateReady'));
        } else {
          _respondError(extra, 400, 'PASSWORD_HASH_INVALID');
        }
      case 'getMe':
        _respond(extra, _meJson());
      case 'getChats':
        _respond(extra, <String, Object?>{
          '@type': 'chats',
          'chat_ids': <int>[1001, 1002],
        });
      case 'getChat':
        _respond(extra, _chatJson((req['chat_id'] as num).toInt()));
      case 'getChatHistory':
        _respond(extra, _historyJson((req['chat_id'] as num).toInt()));
      case 'getUser':
        _respond(extra, _userJson((req['user_id'] as num).toInt()));
      case 'sendMessage':
        _respond(extra, _sentMessageJson(req));
      case 'logOut':
        _respond(extra, <String, Object?>{'@type': 'ok'});
        _updates.add(_authUpdate('authorizationStateClosed'));
      default:
        _respond(extra, <String, Object?>{'@type': 'ok'});
    }
  }

  @override
  String? receive(int clientId, double timeoutSeconds) {
    if (_updates.isEmpty) return null;
    return _updates.removeAt(0);
  }

  @override
  String? execute(int clientId, String requestJson) =>
      '{"@type":"ok"}';

  @override
  void destroy(int clientId) {}

  void _respond(Object? extra, Map<String, Object?> body) {
    _updates.add(jsonEncode(<String, Object?>{...body, '@extra': extra}));
  }

  void _respondError(Object? extra, int code, String message) {
    _updates.add(jsonEncode(<String, Object?>{
      '@type': 'error',
      '@extra': extra,
      'code': code,
      'message': message,
    }));
  }

  static String _authUpdate(String state) => jsonEncode(<String, Object?>{
        '@type': 'updateAuthorizationState',
        'authorization_state': <String, Object?>{'@type': state},
      });

  static Map<String, Object?> _meJson() => <String, Object?>{
        '@type': 'user',
        'id': 1,
        'first_name': 'Test',
        'last_name': 'User',
        'usernames': <String, Object?>{
          '@type': 'usernames',
          'active_usernames': <String>['testuser'],
        },
      };

  static Map<String, Object?> _userJson(int userId) {
    final String name = switch (userId) {
      42 => 'Alice',
      43 => 'Bob',
      _ => 'User $userId',
    };
    return <String, Object?>{
      '@type': 'user',
      'id': userId,
      'first_name': name,
      'last_name': '',
    };
  }

  static Map<String, Object?> _messageJson({
    required int id,
    required int chatId,
    required int senderUserId,
    required String text,
    required bool isOutgoing,
    String contentType = 'messageText',
  }) =>
      <String, Object?>{
        '@type': 'message',
        'id': id,
        'chat_id': chatId,
        'sender_id': <String, Object?>{
          '@type': 'messageSenderUser',
          'user_id': senderUserId,
        },
        'is_outgoing': isOutgoing,
        'date': 1763300000,
        'content': contentType == 'messageText'
            ? <String, Object?>{
                '@type': 'messageText',
                'text': <String, Object?>{
                  '@type': 'formattedText',
                  'text': text,
                  'entities': <Object?>[],
                },
              }
            : <String, Object?>{'@type': contentType},
      };

  static Map<String, Object?> _chatJson(int chatId) {
    if (chatId == 1001) {
      return <String, Object?>{
        '@type': 'chat',
        'id': 1001,
        'type': <String, Object?>{'@type': 'chatTypePrivate'},
        'title': 'Alice',
        'unread_count': 3,
        'last_message': _messageJson(
          id: 501,
          chatId: 1001,
          senderUserId: 42,
          text: 'Hello from Alice!',
          isOutgoing: false,
        ),
      };
    }
    return <String, Object?>{
      '@type': 'chat',
      'id': 1002,
      'type': <String, Object?>{'@type': 'chatTypeSupergroup'},
      'title': 'Flutter Group',
      'unread_count': 0,
      'last_message': _messageJson(
        id: 601,
        chatId: 1002,
        senderUserId: 43,
        text: '',
        isOutgoing: false,
        contentType: 'messagePhoto',
      ),
    };
  }

  static Map<String, Object?> _historyJson(int chatId) {
    if (chatId == 1001) {
      return <String, Object?>{
        '@type': 'messages',
        'messages': <Object?>[
          _messageJson(
            id: 501,
            chatId: 1001,
            senderUserId: 42,
            text: 'Hello from Alice!',
            isOutgoing: false,
          ),
          _messageJson(
            id: 502,
            chatId: 1001,
            senderUserId: 1,
            text: 'Hi Alice!',
            isOutgoing: true,
          ),
        ],
      };
    }
    return <String, Object?>{
      '@type': 'messages',
      'messages': <Object?>[],
    };
  }

  static Map<String, Object?> _sentMessageJson(
    Map<String, dynamic> request,
  ) {
    final Map<String, dynamic> content =
        request['input_message_content'] as Map<String, dynamic>;
    final Map<String, dynamic> text =
        content['text'] as Map<String, dynamic>;
    return _messageJson(
      id: 999,
      chatId: (request['chat_id'] as num).toInt(),
      senderUserId: 1,
      text: (text['text'] as String?) ?? '',
      isOutgoing: true,
    );
  }
}

/// In-memory account store: the real one wraps flutter_secure_storage,
/// which has no platform channel in tests.
class FakeAccountStore extends AccountStore {
  final Map<String, String> values = <String, String>{};

  @override
  Future<void> saveValue(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<String?> readValue(String key) async => values[key];

  @override
  Future<void> deleteValue(String key) async {
    values.remove(key);
  }
}

/// Drives [future] to completion by pumping the fake transport and
/// yielding to microtasks between pumps, so the client's
/// request/response loop can run. Throws if the future does not
/// complete (e.g. the fake ran out of scripted updates).
Future<T> drive<T>(
  Future<T> future,
  FakeTdlibTransport fake,
  TdlibClient client,
) async {
  bool done = false;
  Object? error;
  StackTrace? stack;
  unawaited(future.then(
    (_) => done = true,
    onError: (Object e, StackTrace s) {
      error = e;
      stack = s;
      done = true;
    },
  ));
  for (int i = 0; i < 200 && !done; i++) {
    while (fake.hasPendingUpdates) {
      client.pump();
    }
    // Let the client's continuations run; they may send the next
    // request, which enqueues more updates for the next round.
    // NOTE: a zero-duration delayed future (not Future.value) is
    // required here: flutter_test runs tests in a FakeAsync zone,
    // where the client's stream/timer machinery only advances when
    // the zone flushes timers, and Future.value() does not trigger
    // that flush.
    await Future<void>.delayed(Duration.zero);
  }
  if (!done) {
    throw StateError('drive() timed out waiting for the future');
  }
  if (error != null) Error.throwWithStackTrace(error!, stack!);
  return future;
}

void main() {
  late FakeTdlibTransport fake;
  late TdlibClient client;
  late FakeAccountStore store;
  late TelegramAdapter adapter;

  setUp(() {
    fake = FakeTdlibTransport();
    client = TdlibClient(
      transport: fake,
      config: const TdlibConfig(
        apiId: 12345,
        apiHash: 'testhash',
        databaseDirectory: '/tmp/tdlib-test',
        filesDirectory: '/tmp/tdlib-test/files',
        dbEncryptionKey: 'aabbcc',
      ),
      autoPump: false,
    );
    store = FakeAccountStore();
    adapter = TelegramAdapter(client: client, accountStore: store);
  });

  tearDown(() {
    client.dispose();
  });

  Future<void> logIn() async {
    // Write credentials straight to the store: adapter.saveCredentials
    // drops the client reference (correct for production, where the
    // adapter owns the client), but these tests inject their client.
    await store.saveValue('telegram_api_id', '12345');
    await store.saveValue('telegram_api_hash', 'testhash');
    await drive(adapter.login(), fake, client);
    await drive(
      adapter.submitPhoneNumber('+8613800000000'),
      fake,
      client,
    );
    await drive(adapter.submitCode('12345'), fake, client);
  }

  test('login flow completes and the account is visible', () async {
    await logIn();
    expect(await adapter.isLoggedIn, isTrue);
    // getMe() is a TDLib request, so it needs the pump driver too.
    final TelegramAccount? account =
        await drive(adapter.account, fake, client);
    expect(account?.displayName, 'Test User');
    expect(account?.handle, 'testuser');
    expect(adapter.status, PlatformStatus.limited);
  });

  test('fetchChats returns chats with last messages', () async {
    await logIn();
    final List<TelegramChat> chats =
        await drive(adapter.fetchChats(), fake, client);
    expect(chats, hasLength(2));
    expect(chats[0].title, 'Alice');
    expect(chats[0].type, 'private');
    expect(chats[0].unreadCount, 3);
    expect(chats[0].lastMessage?.text, 'Hello from Alice!');
    expect(chats[1].title, 'Flutter Group');
    expect(chats[1].type, 'supergroup');
    // Non-text content becomes a placeholder, never a blank.
    expect(chats[1].lastMessage?.text, '[photo]');
  });

  test('fetchMessages returns messages with sender names', () async {
    await logIn();
    final List<TelegramMessage> messages =
        await drive(adapter.fetchMessages(1001), fake, client);
    expect(messages, hasLength(2));
    expect(messages[0].text, 'Hello from Alice!');
    expect(messages[0].senderName, 'Alice');
    expect(messages[0].isOutgoing, isFalse);
    expect(messages[1].text, 'Hi Alice!');
    expect(messages[1].senderName, 'You');
    expect(messages[1].isOutgoing, isTrue);
  });

  test('sendMessage returns the sent message', () async {
    await logIn();
    final TelegramMessage sent =
        await drive(adapter.sendMessage(1001, 'Hello!'), fake, client);
    expect(sent.text, 'Hello!');
    expect(sent.chatId, 1001);
    expect(sent.isOutgoing, isTrue);
    expect(sent.senderName, 'You');
  });

  test('fetchTimeline maps chats to posts', () async {
    await logIn();
    final List<Post> posts =
        await drive(adapter.fetchTimeline(), fake, client);
    expect(posts, hasLength(2));
    expect(posts[0].authorName, 'Alice');
    expect(posts[0].text, 'Hello from Alice!');
    expect(posts[0].platformId, 'telegram');
    expect(posts[1].authorName, 'Flutter Group');
  });

  test('fetchTimeline is empty for guests', () async {
    expect(await adapter.fetchTimeline(), isEmpty);
    expect(await adapter.isLoggedIn, isFalse);
  });

  test('login without credentials throws', () async {
    // No injected client here: with one, _ensureClient would return
    // it without ever checking credentials. The fresh adapter takes
    // the real path and throws before touching TDLib.
    final TelegramAdapter fresh = TelegramAdapter(accountStore: store);
    await expectLater(
      fresh.login(),
      throwsA(isA<TelegramCredentialsMissingException>()),
    );
  });

  test('saveCredentials stores the API credentials', () async {
    final TelegramAdapter fresh =
        TelegramAdapter(accountStore: store);
    await fresh.saveCredentials(apiId: 12345, apiHash: 'testhash');
    expect(await store.readValue('telegram_api_id'), '12345');
    expect(await store.readValue('telegram_api_hash'), 'testhash');
    expect(await fresh.credentialsConfigured, isTrue);
  });

  test('invalid phone number throws TdlibException', () async {
    await store.saveValue('telegram_api_id', '12345');
    await store.saveValue('telegram_api_hash', 'testhash');
    await drive(adapter.login(), fake, client);
    await expectLater(
      () => drive(adapter.submitPhoneNumber('not-a-number'), fake, client),
      throwsA(
        isA<TdlibException>().having(
          (TdlibException e) => e.message,
          'message',
          'PHONE_NUMBER_INVALID',
        ),
      ),
    );
  });

  test('wrong code throws TdlibException', () async {
    await store.saveValue('telegram_api_id', '12345');
    await store.saveValue('telegram_api_hash', 'testhash');
    await drive(adapter.login(), fake, client);
    await drive(
      adapter.submitPhoneNumber('+8613800000000'),
      fake,
      client,
    );
    await expectLater(
      () => drive(adapter.submitCode('00000'), fake, client),
      throwsA(
        isA<TdlibException>().having(
          (TdlibException e) => e.message,
          'message',
          'PHONE_CODE_INVALID',
        ),
      ),
    );
  });

  test('logout clears the session but keeps API credentials', () async {
    await logIn();
    expect(await adapter.isLoggedIn, isTrue);
    await drive(adapter.logout(), fake, client);
    expect(await adapter.isLoggedIn, isFalse);
    expect(await store.readValue('telegram_db_key'), isNull);
    expect(await adapter.credentialsConfigured, isTrue);
  });
}
