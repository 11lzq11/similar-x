// Mastodon adapter tests, driven by a scripted fake HTTP transport.
//
// No real instance, network or account is involved: [MockClient]
// answers Mastodon REST calls with canned JSON. The OAuth flow is
// exercised end to end (app registration -> authorize URL with PKCE
// -> code exchange -> token stored -> verify credentials).

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:similar_x/adapters/mastodon/mastodon_client.dart';
import 'package:similar_x/adapters/mastodon/mastodon_models.dart';
import 'package:similar_x/adapters/mastodon_adapter.dart';
import 'package:similar_x/core/account_store.dart';
import 'package:similar_x/core/platform_adapter.dart';

/// In-memory account store: the real one wraps flutter_secure_storage,
/// which has no platform channel in tests.
class FakeAccountStore extends AccountStore {
  final Map<String, String> values = <String, String>{};

  @override
  Future<void> saveToken(String platformId, String token) async {
    values['similar_x_token_$platformId'] = token;
  }

  @override
  Future<String?> readToken(String platformId) async =>
      values['similar_x_token_$platformId'];

  @override
  Future<void> deleteToken(String platformId) async {
    values.remove('similar_x_token_$platformId');
  }

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

Map<String, Object?> accountJson({
  String id = '1',
  String username = 'alice',
  String acct = 'alice@mastodon.social',
  String displayName = 'Alice',
}) =>
    <String, Object?>{
      'id': id,
      'username': username,
      'acct': acct,
      'display_name': displayName,
      'avatar_static': 'https://mastodon.social/avatar.png',
      'followers_count': 10,
      'following_count': 5,
      'statuses_count': 42,
      'note': '<p>Hi there</p>',
    };

Map<String, Object?> statusJson({
  String id = '100',
  Map<String, Object?>? account,
  String content = '<p>Hello world</p>',
  int favourites = 0,
  int reblogs = 0,
  int replies = 0,
  bool favourited = false,
  bool reblogged = false,
  Map<String, Object?>? reblog,
  String? inReplyToId,
}) =>
    <String, Object?>{
      'id': id,
      'account': account ?? accountJson(),
      'content': content,
      'created_at': '2026-11-16T12:00:00.000Z',
      'reblogs_count': reblogs,
      'favourites_count': favourites,
      'replies_count': replies,
      'favourited': favourited,
      'reblogged': reblogged,
      'visibility': 'public',
      'url': 'https://mastodon.social/@alice/$id',
      'reblog': reblog,
      'in_reply_to_id': inReplyToId,
    };

/// A fake Mastodon instance (mastodon.social) answering every call
/// the adapter makes, plus a dead one (offline.invalid) that throws
/// [http.ClientException] to simulate a bad/unreachable instance.
class FakeMastodonServer {
  FakeMastodonServer() {
    client = MockClient(_handle);
  }

  late final MockClient client;
  final List<http.Request> sentRequests = <http.Request>[];

  Future<http.Response> _handle(http.Request request) async {
    sentRequests.add(request);
    final String host = request.url.host;
    if (host == 'offline.invalid') {
      throw http.ClientException('Failed host lookup', request.url);
    }
    final String path = request.url.path;
    final String method = request.method;
    if (method == 'POST' && path == '/api/v1/apps') {
      return _json(<String, Object?>{
        'client_id': 'test-client-id',
        'client_secret': 'test-client-secret',
        'redirect_uri': mastodonOobRedirect,
      });
    }
    if (method == 'POST' && path == '/oauth/token') {
      final Map<String, String> fields = request.bodyFields;
      if (fields['code'] == 'valid-code' &&
          fields['code_verifier'] != null &&
          fields['code_verifier']!.isNotEmpty) {
        return _json(<String, Object?>{
          'access_token': 'test-access-token',
          'token_type': 'Bearer',
          'scope': 'read write follow',
          'created_at': 1763300000,
        });
      }
      return _json(
        <String, Object?>{'error': 'invalid_grant'},
        status: 400,
      );
    }
    if (method == 'GET' &&
        path == '/api/v1/accounts/verify_credentials') {
      return _json(accountJson());
    }
    if (method == 'GET' && path == '/api/v1/timelines/home') {
      final String? auth =
          request.headers['Authorization'];
      if (auth == 'Bearer bad-token') {
        return _json(
          <String, Object?>{'error': 'The access token is invalid'},
          status: 401,
        );
      }
      return _json(<Object?>[
        statusJson(
          content:
              '<p>Hello <a href="https://example.com">world</a> &amp; friends</p>',
          favourites: 5,
          reblogs: 2,
          replies: 1,
        ),
        statusJson(
          id: '200',
          account: accountJson(
            id: '2',
            username: 'bob',
            acct: 'bob@mastodon.social',
            displayName: 'Bob',
          ),
          content: '<p>Boosted by Bob</p>',
          reblog: statusJson(
            id: '101',
            account: accountJson(
              id: '3',
              username: 'carol',
              acct: 'carol@mastodon.social',
              displayName: 'Carol',
            ),
            content: '<p>Original toot</p>',
          ),
        ),
      ]);
    }
    if (method == 'GET' && path == '/api/v1/timelines/public') {
      return _json(<Object?>[
        statusJson(
          id: '300',
          account: accountJson(
            id: '4',
            username: 'dave',
            acct: 'dave@mastodon.social',
            displayName: 'Dave',
          ),
          content: '<p>Public post</p><p>Second line</p>',
        ),
      ]);
    }
    if (method == 'POST' && path == '/api/v1/statuses') {
      final Map<String, String> fields = request.bodyFields;
      final String text = fields['status'] ?? '';
      return _json(
        statusJson(
          id: '9001',
          content: '<p>$text</p>',
          inReplyToId: fields['in_reply_to_id'],
        ),
        status: 201,
      );
    }
    final RegExp action = RegExp(
      r'^/api/v1/statuses/(\w+)/(favourite|unfavourite|reblog|unreblog)$',
    );
    final RegExpMatch? actionMatch = action.firstMatch(path);
    if (method == 'POST' && actionMatch != null) {
      final String statusId = actionMatch.group(1)!;
      final String verb = actionMatch.group(2)!;
      return _json(statusJson(
        id: statusId,
        favourited: verb == 'favourite',
        reblogged: verb == 'reblog',
        favourites: verb == 'favourite' ? 6 : 5,
        reblog: verb == 'reblog'
            ? statusJson(id: statusId)
            : null,
      ));
    }
    if (method == 'GET' && path == '/api/v1/notifications') {
      return _json(<Object?>[
        <String, Object?>{
          'id': 'n1',
          'type': 'mention',
          'created_at': '2026-11-16T12:00:00.000Z',
          'account': accountJson(
            id: '2',
            username: 'bob',
            acct: 'bob@mastodon.social',
            displayName: 'Bob',
          ),
          'status': statusJson(id: '500', content: '<p>@alice hi</p>'),
        },
        <String, Object?>{
          'id': 'n2',
          'type': 'favourite',
          'created_at': '2026-11-16T12:00:00.000Z',
          'account': accountJson(
            id: '3',
            username: 'carol',
            acct: 'carol@mastodon.social',
            displayName: 'Carol',
          ),
        },
      ]);
    }
    final RegExp follow = RegExp(
      r'^/api/v1/accounts/(\w+)/(follow|unfollow)$',
    );
    final RegExpMatch? followMatch = follow.firstMatch(path);
    if (method == 'POST' && followMatch != null) {
      return _json(<String, Object?>{
        'id': followMatch.group(1),
        'following': followMatch.group(2) == 'follow',
        'followed_by': false,
      });
    }
    if (method == 'GET' && path == '/api/v2/search') {
      final String type = request.url.queryParameters['type'] ?? '';
      if (type == 'accounts') {
        return _json(<String, Object?>{
          'accounts': <Object?>[
            accountJson(
              id: '1',
              username: 'alice',
              acct: 'alice@mastodon.social',
              displayName: 'Alice',
            ),
          ],
          'statuses': <Object?>[],
          'hashtags': <Object?>[],
        });
      }
      return _json(<String, Object?>{
        'accounts': <Object?>[],
        'statuses': <Object?>[
          statusJson(id: '700', content: '<p>Found it</p>'),
        ],
        'hashtags': <Object?>[],
      });
    }
    return _json(<String, Object?>{'error': 'not found'}, status: 404);
  }

  http.Response _json(Object? body, {int status = 200}) =>
      http.Response(jsonEncode(body), status, headers: <String, String>{
        'content-type': 'application/json',
      });
}

void main() {
  late FakeMastodonServer server;
  late FakeAccountStore store;
  late MastodonAdapter adapter;

  setUp(() {
    server = FakeMastodonServer();
    store = FakeAccountStore();
    adapter = MastodonAdapter(
      client: MastodonClient(
        instance: 'mastodon.social',
        httpClient: server.client,
      ),
      accountStore: store,
    );
  });

  Future<void> logIn() async {
    await adapter.beginLogin();
    await adapter.submitAuthorizationCode('valid-code');
  }

  test('PKCE challenge is base64url(SHA-256) of the verifier', () {
    // Known vector: SHA-256("abc") =
    // ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
    expect(
      codeChallengeS256('abc'),
      'ungWv48Bz-pBQUDeXa4iI7ADYaOWF3qctBD_YfIAFa0',
    );
    final String verifier = generateCodeVerifier();
    expect(verifier.length, greaterThanOrEqualTo(43));
    expect(verifier.length, lessThanOrEqualTo(128));
    expect(verifier, isNot(contains('=')));
    expect(codeChallengeS256(verifier), isNot(verifier));
  });

  test('stripHtml removes tags and decodes entities', () {
    expect(
      stripHtml('<p>Hello <a href="https://x">world</a></p><p>Second</p>'),
      'Hello world\nSecond',
    );
    expect(stripHtml('Fish &amp; Chips &lt;3 &#39;quoted&#39;'), "Fish & Chips <3 'quoted'");
    expect(stripHtml('Line one<br>Line two'), 'Line one\nLine two');
    expect(stripHtml(''), '');
  });

  test('instance names are normalized and validated', () async {
    await adapter.setInstance('https://mastodon.social/');
    expect(await adapter.instance, 'mastodon.social');
    await adapter.setInstance('Mastodon.Social');
    expect(await adapter.instance, 'mastodon.social');
    await expectLater(
      adapter.setInstance('not a domain'),
      throwsA(isA<MastodonApiException>()),
    );
    await expectLater(
      adapter.setInstance('example'),
      throwsA(isA<MastodonApiException>()),
    );
    await expectLater(
      adapter.setInstance(''),
      throwsA(isA<MastodonApiException>()),
    );
  });

  test('login flow registers the app and returns a PKCE authorize URL',
      () async {
    final Uri url = await adapter.beginLogin();
    expect(url.host, 'mastodon.social');
    expect(url.path, '/oauth/authorize');
    expect(url.queryParameters['response_type'], 'code');
    expect(url.queryParameters['client_id'], 'test-client-id');
    expect(url.queryParameters['redirect_uri'], mastodonOobRedirect);
    expect(url.queryParameters['code_challenge_method'], 'S256');
    final String? verifier = await store.readValue(
      'mastodon_code_verifier',
    );
    expect(verifier, isNotNull);
    final String expectedChallenge = base64Url
        .encode(sha256.convert(utf8.encode(verifier!)).bytes)
        .replaceAll('=', '');
    expect(url.queryParameters['code_challenge'], expectedChallenge);
    expect(adapter.authorizeUrl, url);
    // App credentials are stored, so a second login reuses them.
    expect(
      await store.readValue('mastodon_client_id'),
      'test-client-id',
    );
    final int appCalls = server.sentRequests
        .where((http.Request r) => r.url.path == '/api/v1/apps')
        .length;
    await adapter.beginLogin();
    expect(
      server.sentRequests
          .where((http.Request r) => r.url.path == '/api/v1/apps')
          .length,
      appCalls,
    );
  });

  test('code exchange stores the token and verifies the account',
      () async {
    await logIn();
    expect(await adapter.isLoggedIn, isTrue);
    expect(await store.readToken('mastodon'), 'test-access-token');
    expect(await store.readValue('mastodon_code_verifier'), isNull);
    final MastodonAccount? account = await adapter.account;
    expect(account?.displayName, 'Alice');
    expect(account?.acct, 'alice@mastodon.social');
    expect(adapter.status, PlatformStatus.ready);
    expect(adapter.requiresLogin, isFalse);
  });

  test('wrong authorization code throws', () async {
    await adapter.beginLogin();
    await expectLater(
      adapter.submitAuthorizationCode('bad-code'),
      throwsA(isA<MastodonApiException>()),
    );
    expect(await adapter.isLoggedIn, isFalse);
  });

  test('home timeline parses HTML, counts and boosts', () async {
    await logIn();
    final List<Post> posts = await adapter.fetchTimeline();
    expect(posts, hasLength(2));
    expect(posts[0].authorName, 'Alice');
    expect(posts[0].text, 'Hello world & friends');
    expect(posts[0].likeCount, 5);
    expect(posts[0].repostCount, 2);
    expect(posts[0].replyCount, 1);
    expect(posts[0].platformId, 'mastodon');
    // A boost shows the original status and its author.
    expect(posts[1].authorName, 'Carol');
    expect(posts[1].text, 'Original toot');
  });

  test('guests get the public timeline without logging in', () async {
    expect(await adapter.isLoggedIn, isFalse);
    final List<Post> posts = await adapter.fetchTimeline();
    expect(posts, hasLength(1));
    expect(posts[0].authorName, 'Dave');
    expect(posts[0].text, 'Public post\nSecond line');
  });

  test('post and reply send the right fields', () async {
    await logIn();
    final MastodonStatus posted = await adapter.postStatus('Hello fediverse');
    expect(posted.id, '9001');
    expect(posted.content, 'Hello fediverse');
    final MastodonStatus reply =
        await adapter.reply('100', 'Replying here');
    expect(reply.inReplyToId, '100');
    final http.Request replyRequest = server.sentRequests.lastWhere(
      (http.Request r) => r.url.path == '/api/v1/statuses',
    );
    expect(replyRequest.bodyFields['in_reply_to_id'], '100');
    expect(replyRequest.bodyFields['status'], 'Replying here');
  });

  test('favourite, unfavourite, reblog and unreblog', () async {
    await logIn();
    final MastodonStatus liked = await adapter.favourite('100');
    expect(liked.favourited, isTrue);
    expect(liked.favouritesCount, 6);
    final MastodonStatus unliked = await adapter.unfavourite('100');
    expect(unliked.favourited, isFalse);
    final MastodonStatus boosted = await adapter.reblog('100');
    expect(boosted.reblogged, isTrue);
    expect(boosted.reblog?.id, '100');
    final MastodonStatus unboosted = await adapter.unreblog('100');
    expect(unboosted.reblogged, isFalse);
  });

  test('notifications list mentions and favourites', () async {
    await logIn();
    final List<MastodonNotification> notes =
        await adapter.fetchNotifications();
    expect(notes, hasLength(2));
    expect(notes[0].type, 'mention');
    expect(notes[0].account.name, 'Bob');
    expect(notes[0].status?.content, '@alice hi');
    expect(notes[1].type, 'favourite');
    expect(notes[1].account.name, 'Carol');
    expect(notes[1].status, isNull);
  });

  test('follow and unfollow update the relationship', () async {
    await logIn();
    final MastodonRelationship followed =
        await adapter.followAccount('42');
    expect(followed.following, isTrue);
    final MastodonRelationship unfollowed =
        await adapter.unfollowAccount('42');
    expect(unfollowed.following, isFalse);
  });

  test('search finds accounts and statuses', () async {
    await logIn();
    final List<MastodonAccount> accounts =
        await adapter.searchAccounts('alice');
    expect(accounts, hasLength(1));
    expect(accounts[0].acct, 'alice@mastodon.social');
    final List<MastodonStatus> statuses =
        await adapter.searchStatuses('found');
    expect(statuses, hasLength(1));
    expect(statuses[0].content, 'Found it');
  });

  test('unreachable instance throws a clear error', () async {
    await adapter.setInstance('offline.invalid');
    await expectLater(
      adapter.beginLogin(),
      throwsA(
        isA<MastodonApiException>().having(
          (MastodonApiException e) => e.message,
          'message',
          contains('Could not reach offline.invalid'),
        ),
      ),
    );
  });

  test('a revoked token surfaces as a 401 error', () async {
    await store.saveToken('mastodon', 'bad-token');
    await expectLater(
      adapter.fetchTimeline(),
      throwsA(
        isA<MastodonApiException>().having(
          (MastodonApiException e) => e.statusCode,
          'statusCode',
          401,
        ),
      ),
    );
  });

  test('actions without login throw', () async {
    await expectLater(
      adapter.postStatus('nope'),
      throwsA(isA<MastodonNotLoggedInException>()),
    );
    await expectLater(
      adapter.favourite('100'),
      throwsA(isA<MastodonNotLoggedInException>()),
    );
    await expectLater(
      adapter.fetchNotifications(),
      throwsA(isA<MastodonNotLoggedInException>()),
    );
    await expectLater(
      adapter.followAccount('42'),
      throwsA(isA<MastodonNotLoggedInException>()),
    );
  });

  test('logout clears the token but keeps the instance', () async {
    await logIn();
    expect(await adapter.isLoggedIn, isTrue);
    await adapter.logout();
    expect(await adapter.isLoggedIn, isFalse);
    expect(await store.readToken('mastodon'), isNull);
    expect(await adapter.instance, 'mastodon.social');
  });

  test('switching instances forgets the login', () async {
    await logIn();
    expect(await adapter.isLoggedIn, isTrue);
    await adapter.setInstance('fosstodon.org');
    expect(await adapter.isLoggedIn, isFalse);
    expect(await adapter.instance, 'fosstodon.org');
  });
}
