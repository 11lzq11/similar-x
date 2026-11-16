// Reddit adapter tests, driven by a scripted fake HTTP transport.
//
// No real Reddit API, network or account is involved: [MockClient]
// answers the OAuth token endpoint, oauth.reddit.com and the public
// www.reddit.com JSON endpoints with canned JSON. The OAuth flow is
// exercised end to end (authorize URL -> loopback code -> token
// exchange -> tokens stored), including the access-token refresh on
// a 401 and the guest app-only token. The loopback listener test
// uses real TCP on 127.0.0.1 only.

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:similar_x/adapters/reddit/reddit_client.dart';
import 'package:similar_x/adapters/reddit/reddit_models.dart';
import 'package:similar_x/adapters/reddit_adapter.dart';
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

const String testClientId = 'test-client-id-123';
const String testAccessToken = 'test-access-token';
const String testRefreshToken = 'test-refresh-token';
const String testAppOnlyToken = 'test-app-only-token';

Map<String, Object?> postData({
  String id = 'abc123',
  String title = 'Test Post',
  String author = 'testuser',
  String subreddit = 'flutter',
  int score = 42,
  int comments = 7,
  double createdUtc = 1794837600.0,
  String selftext = '',
  bool? likes,
  bool saved = false,
}) =>
    <String, Object?>{
      'id': id,
      'name': 't3_$id',
      'title': title,
      'author': author,
      'subreddit': subreddit,
      'subreddit_name_prefixed': 'r/$subreddit',
      'selftext': selftext,
      'url': 'https://example.com/post',
      'permalink': '/r/$subreddit/comments/$id/test_post/',
      'thumbnail': 'https://example.com/thumb.jpg',
      'domain': 'example.com',
      'is_self': selftext.isNotEmpty,
      'over_18': false,
      'saved': saved,
      'likes': likes,
      'score': score,
      'upvote_ratio': 0.95,
      'num_comments': comments,
      'created_utc': createdUtc,
    };

Map<String, Object?> commentData({
  String id = 'c1',
  String body = 'Test comment',
  String author = 'commenter',
  int score = 5,
  int depth = 0,
  Object? replies = '',
}) =>
    <String, Object?>{
      'id': id,
      'name': 't1_$id',
      'body': body,
      'author': author,
      'score': score,
      'created_utc': 1794837600.0,
      'depth': depth,
      'parent_id': 't3_abc123',
      'link_id': 't3_abc123',
      'replies': replies,
    };

Map<String, Object?> subredditData({
  String name = 'flutter',
  int subscribers = 123456,
  bool subscribed = false,
}) =>
    <String, Object?>{
      'display_name': name,
      'title': 'Flutter',
      'public_description': 'A subreddit about Flutter.',
      'subscribers': subscribers,
      'icon_img': 'https://example.com/icon.png',
      'url': '/r/$name/',
      'over_18': false,
      'user_is_subscriber': subscribed,
    };

Map<String, Object?> messageData({
  String id = 'm1',
  String kind = 't1',
  String subject = 'comment reply',
  String body = 'Reply body',
  String author = 'replier',
  bool isNew = true,
}) =>
    <String, Object?>{
      'id': id,
      'name': '${kind}_$id',
      'subject': subject,
      'body': body,
      'author': author,
      'created_utc': 1794837600.0,
      'new': isNew,
    };

Map<String, Object?> listingJson(
  List<Map<String, Object?>> children, {
  String kind = 't3',
}) =>
    <String, Object?>{
      'kind': 'Listing',
      'data': <String, Object?>{
        'children': children
            .map((Map<String, Object?> c) =>
                <String, Object?>{'kind': kind, 'data': c})
            .toList(),
        'after': null,
        'before': null,
      },
    };

Map<String, Object?> tokenJson({
  String access = testAccessToken,
  String? refresh = testRefreshToken,
  int expiresIn = 3600,
}) =>
    <String, Object?>{
      'access_token': access,
      'token_type': 'Bearer',
      'expires_in': expiresIn,
      'refresh_token': refresh,
      'scope': redditOAuthScope,
    };

/// Scriptable fake transport. [expireOnce] makes the first
/// authenticated GET to /best answer 401 (to exercise the
/// refresh-and-retry). [refreshFails] makes the token endpoint
/// reject refresh_token grants. [requests] records every request
/// for assertions.
class ScriptedTransport {
  ScriptedTransport({
    this.expireOnce = false,
    this.refreshFails = false,
  });

  final bool expireOnce;
  final bool refreshFails;
  final List<http.Request> requests = <http.Request>[];
  bool _expired = false;

  http.Client get client => MockClient(_handler);

  Future<http.Response> _handler(http.Request request) async {
    requests.add(request);
    final Uri uri = request.url;

    // Token endpoint (www.reddit.com/api/v1/access_token).
    if (uri.host == 'www.reddit.com' &&
        uri.path == '/api/v1/access_token') {
      final Map<String, String> fields =
          Uri.splitQueryString(request.body);
      final String grant = fields['grant_type'] ?? '';
      if (grant == 'authorization_code') {
        return _json(tokenJson());
      }
      if (grant == 'refresh_token') {
        if (refreshFails) {
          return _json(
            <String, Object?>{
              'message': 'invalid_grant',
              'error': 400,
            },
            400,
          );
        }
        return _json(tokenJson(access: 'refreshed-access-token'));
      }
      if (grant == 'client_credentials') {
        return _json(<String, Object?>{
          'access_token': testAppOnlyToken,
          'token_type': 'Bearer',
          'expires_in': 3600,
          'scope': '*',
        });
      }
      return _json(
        <String, Object?>{'message': 'unsupported grant'},
        400,
      );
    }

    // OAuth API host.
    if (uri.host == 'oauth.reddit.com') {
      if (expireOnce && uri.path == '/best' && !_expired) {
        _expired = true;
        return _json(
          <String, Object?>{'message': 'Unauthorized'},
          401,
        );
      }
      switch (uri.path) {
        case '/api/v1/me':
          return _json(<String, Object?>{
            'name': 'testuser',
            'id': 'u123',
            'icon_img': 'https://example.com/avatar.png',
            'link_karma': 100,
            'comment_karma': 50,
            'created_utc': 1700000000.0,
          });
        case '/best':
        case '/hot':
          return _json(listingJson(<Map<String, Object?>>[
            postData(),
            postData(
              id: 'def456',
              title: 'Second Post',
              author: 'other',
              score: 10,
              comments: 2,
            ),
          ]));
        case '/r/flutter/hot':
        case '/r/flutter/new':
          return _json(listingJson(<Map<String, Object?>>[
            postData(),
          ]));
        case '/r/flutter/about':
          return _json(subredditData(subscribed: true));
        case '/r/popular/hot':
          return _json(listingJson(<Map<String, Object?>>[
            postData(title: 'Popular Post', subreddit: 'popular'),
          ]));
        case '/search':
          if (uri.queryParameters['type'] == 'sr') {
            return _json(listingJson(
              <Map<String, Object?>>[subredditData()],
              kind: 't5',
            ));
          }
          return _json(listingJson(<Map<String, Object?>>[
            postData(title: 'Search Hit'),
          ]));
        case '/api/submit':
          final Map<String, String> fields =
              Uri.splitQueryString(request.body);
          if ((fields['title'] ?? '').isEmpty) {
            return _json(<String, Object?>{
              'json': <String, Object?>{
                'errors': <Object?>[
                  <Object?>['NO_TITLE', 'we need a title', 'title'],
                ],
                'data': <String, Object?>{},
              },
            });
          }
          return _json(<String, Object?>{
            'json': <String, Object?>{
              'errors': <Object?>[],
              'data': <String, Object?>{
                'name': 't3_newpost',
                'url':
                    'https://www.reddit.com/r/flutter/comments/newpost/',
              },
            },
          });
        case '/api/comment':
          return _json(<String, Object?>{
            'json': <String, Object?>{
              'errors': <Object?>[],
              'data': <String, Object?>{
                'things': <Object?>[
                  <String, Object?>{
                    'kind': 't1',
                    'data': commentData(
                      id: 'c9',
                      body: 'Fresh comment',
                    ),
                  },
                ],
              },
            },
          });
        case '/api/vote':
        case '/api/save':
        case '/api/unsave':
        case '/api/subscribe':
          return http.Response('', 200);
        case '/subreddits/mine/subscriber':
          return _json(listingJson(
            <Map<String, Object?>>[
              subredditData(subscribed: true),
              subredditData(name: 'dart', subscribed: true),
            ],
            kind: 't5',
          ));
        case '/message/inbox':
          return _json(<String, Object?>{
            'kind': 'Listing',
            'data': <String, Object?>{
              'children': <Object?>[
                <String, Object?>{
                  'kind': 't1',
                  'data': messageData(),
                },
                <String, Object?>{
                  'kind': 't4',
                  'data': messageData(
                    id: 'm2',
                    kind: 't4',
                    subject: 'Private message',
                    body: 'Hello!',
                    author: 'friend',
                    isNew: false,
                  ),
                },
              ],
              'after': null,
              'before': null,
            },
          });
        case '/api/info':
          return _json(listingJson(<Map<String, Object?>>[
            postData(),
          ]));
        case '/user/testuser/saved':
          return _json(listingJson(<Map<String, Object?>>[
            postData(saved: true),
          ]));
        case '/user/testuser/upvoted':
          return _json(listingJson(<Map<String, Object?>>[
            postData(likes: true),
          ]));
      }
      if (uri.path.startsWith('/r/flutter/comments/')) {
        final Map<String, Object?> nested = commentData(
          id: 'c2',
          body: 'Nested reply',
          depth: 1,
        );
        final Map<String, Object?> top = commentData(
          id: 'c1',
          body: 'Top comment',
          replies: listingJson(
            <Map<String, Object?>>[nested],
            kind: 't1',
          ),
        );
        return _json(<Object?>[
          listingJson(<Map<String, Object?>>[postData()]),
          listingJson(<Map<String, Object?>>[top], kind: 't1'),
        ]);
      }
      return http.Response('Not found: ${uri.path}', 404);
    }

    // Public JSON host.
    if (uri.host == 'www.reddit.com') {
      if (uri.path == '/r/popular/hot.json') {
        return _json(listingJson(<Map<String, Object?>>[
          postData(title: 'Public Popular Post'),
        ]));
      }
      if (uri.path == '/r/flutter/hot.json') {
        return _json(listingJson(<Map<String, Object?>>[
          postData(),
        ]));
      }
      if (uri.path == '/search.json') {
        return _json(listingJson(<Map<String, Object?>>[
          postData(title: 'Public Search Hit'),
        ]));
      }
      if (uri.path == '/comments/abc123.json') {
        return _json(<Object?>[
          listingJson(<Map<String, Object?>>[postData()]),
          listingJson(<Map<String, Object?>>[], kind: 't1'),
        ]);
      }
      if (uri.path == '/r/flutter/comments/abc123.json') {
        final Map<String, Object?> nested = commentData(
          id: 'c2',
          body: 'Nested reply',
          depth: 1,
        );
        final Map<String, Object?> top = commentData(
          id: 'c1',
          body: 'Top comment',
          replies: listingJson(
            <Map<String, Object?>>[nested],
            kind: 't1',
          ),
        );
        return _json(<Object?>[
          listingJson(<Map<String, Object?>>[postData()]),
          listingJson(<Map<String, Object?>>[top], kind: 't1'),
        ]);
      }
      return http.Response('Not found: ${uri.path}', 404);
    }

    return http.Response('Unexpected host: ${uri.host}', 404);
  }

  http.Response _json(Object? body, [int status = 200]) =>
      http.Response(json.encode(body), status);
}

Future<RedditAdapter> loggedInAdapter(
  FakeAccountStore store,
  ScriptedTransport transport,
) async {
  final RedditAdapter adapter = RedditAdapter(
    client: RedditClient(httpClient: transport.client),
    accountStore: store,
  );
  await adapter.setClientId(testClientId);
  await store.saveToken('reddit', testAccessToken);
  await store.saveValue('reddit_refresh_token', testRefreshToken);
  return adapter;
}

void main() {
  group('Reddit models', () {
    test('RedditPost parses a full t3 payload', () {
      final RedditPost post =
          RedditPost.fromJson(postData(selftext: 'Body text'));
      expect(post.isValid, isTrue);
      expect(post.id, 'abc123');
      expect(post.name, 't3_abc123');
      expect(post.title, 'Test Post');
      expect(post.author, 'testuser');
      expect(post.subredditPrefixed, 'r/flutter');
      expect(post.score, 42);
      expect(post.commentCount, 7);
      expect(post.upvoteRatio, closeTo(0.95, 0.001));
      expect(post.webUrl,
          'https://www.reddit.com/r/flutter/comments/abc123/test_post/');
      expect(
        post.createdAt,
        DateTime.fromMillisecondsSinceEpoch(
          (1794837600.0 * 1000).round(),
          isUtc: true,
        ),
      );
    });

    test('RedditPost with missing fields is invalid, not a crash', () {
      final RedditPost post =
          RedditPost.fromJson(<String, dynamic>{});
      expect(post.isValid, isFalse);
      expect(post.score, 0);
      expect(post.createdAt,
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true));
    });

    test('RedditComment parses nested replies recursively', () {
      final Map<String, Object?> nested = commentData(
        id: 'c2',
        body: 'Nested',
        depth: 1,
      );
      final RedditComment top = RedditComment.fromJson(commentData(
        replies: listingJson(
          <Map<String, Object?>>[nested],
          kind: 't1',
        ),
      ));
      expect(top.isValid, isTrue);
      expect(top.replies, hasLength(1));
      expect(top.replies.first.body, 'Nested');
      expect(top.replies.first.depth, 1);
      expect(top.replies.first.replies, isEmpty);
    });

    test('RedditComment with empty-string replies has no replies', () {
      final RedditComment comment =
          RedditComment.fromJson(commentData(replies: ''));
      expect(comment.replies, isEmpty);
    });

    test('RedditSubreddit and RedditTokens parse', () {
      final RedditSubreddit sub =
          RedditSubreddit.fromJson(subredditData());
      expect(sub.isValid, isTrue);
      expect(sub.prefixedName, 'r/flutter');
      expect(sub.subscribers, 123456);
      final RedditTokens userTokens =
          RedditTokens.fromJson(tokenJson());
      expect(userTokens.isValid, isTrue);
      expect(userTokens.isUserToken, isTrue);
      final RedditTokens appTokens = RedditTokens.fromJson(
        <String, Object?>{
          'access_token': 'app',
          'token_type': 'Bearer',
          'expires_in': 3600,
        },
      );
      expect(appTokens.isUserToken, isFalse);
    });
  });

  group('Reddit PKCE', () {
    test('verifier is 86 chars, challenge is SHA-256 of it', () {
      final String verifier = generateCodeVerifier();
      expect(verifier.length, 86);
      expect(verifier.contains('='), isFalse);
      final String challenge = codeChallengeS256(verifier);
      final String expected = base64Url
          .encode(sha256.convert(utf8.encode(verifier)).bytes)
          .replaceAll('=', '');
      expect(challenge, expected);
      expect(challenge.contains('='), isFalse);
    });
  });

  group('Reddit loopback listener', () {
    test('captures the authorization code from the redirect', () async {
      final RedditLoopbackAuthListener listener =
          await RedditLoopbackAuthListener.start();
      final HttpClient httpClient = HttpClient();
      try {
        final HttpClientRequest request = await httpClient.getUrl(
          Uri.parse('${listener.redirectUri}?code=auth-code-123'),
        );
        final HttpClientResponse response = await request.close();
        expect(response.statusCode, 200);
        await response.drain<void>();
        expect(await listener.code, 'auth-code-123');
      } finally {
        httpClient.close();
      }
    });

    test('cancel makes the code future throw', () async {
      final RedditLoopbackAuthListener listener =
          await RedditLoopbackAuthListener.start();
      await listener.cancel();
      await expectLater(
        listener.code,
        throwsA(isA<RedditApiException>()),
      );
    });
  });

  group('Reddit adapter metadata', () {
    test('declares id, name, limited status and capabilities', () {
      final RedditAdapter adapter = RedditAdapter();
      expect(adapter.id, 'reddit');
      expect(adapter.displayName, 'Reddit');
      expect(adapter.status, PlatformStatus.limited);
      expect(adapter.requiresLogin, isFalse);
      expect(
        adapter.capabilities,
        containsAll(<AdapterCapability>{
          AdapterCapability.timeline,
          AdapterCapability.post,
          AdapterCapability.like,
          AdapterCapability.comment,
          AdapterCapability.search,
          AdapterCapability.notifications,
        }),
      );
      expect(adapter.note, contains('100 req/min'));
      expect(adapter.note, contains('manual approval'));
    });
  });

  group('Reddit login flow', () {
    test('authorize URL has the right OAuth parameters', () async {
      final FakeAccountStore store = FakeAccountStore();
      final ScriptedTransport transport = ScriptedTransport();
      final RedditAdapter adapter = RedditAdapter(
        client: RedditClient(httpClient: transport.client),
        accountStore: store,
      );
      await adapter.setClientId(testClientId);
      final Uri url = await adapter.beginOAuthLogin();
      expect(url.host, 'www.reddit.com');
      expect(url.path, '/api/v1/authorize');
      expect(url.queryParameters['client_id'], testClientId);
      expect(url.queryParameters['response_type'], 'code');
      expect(url.queryParameters['duration'], 'permanent');
      expect(url.queryParameters['scope'],
          contains('identity'));
      expect(url.queryParameters['code_challenge_method'], 'S256');
      expect(
        url.queryParameters['code_challenge'],
        isNotEmpty,
      );
      expect(url.queryParameters['state'], isNotEmpty);
      expect(url.queryParameters['redirect_uri'],
          startsWith('http://127.0.0.1:'));
      await adapter.cancelOAuthLogin();
    });

    test('login() without setup throws a helpful error', () async {
      final RedditAdapter adapter = RedditAdapter();
      await expectLater(
        adapter.login(),
        throwsA(isA<RedditApiException>()),
      );
    });

    test('beginOAuthLogin without a client ID throws', () async {
      final RedditAdapter adapter = RedditAdapter(
        client: RedditClient(
          httpClient: ScriptedTransport().client,
        ),
        accountStore: FakeAccountStore(),
      );
      await expectLater(
        adapter.beginOAuthLogin(),
        throwsA(isA<RedditApiException>()),
      );
    });

    test('completeOAuthLogin stores tokens and logs in', () async {
      final FakeAccountStore store = FakeAccountStore();
      final ScriptedTransport transport = ScriptedTransport();
      final RedditAdapter adapter = RedditAdapter(
        client: RedditClient(httpClient: transport.client),
        accountStore: store,
      );
      await adapter.setClientId(testClientId);
      final Uri url = await adapter.beginOAuthLogin();
      // Simulate the browser redirect to the loopback address,
      // echoing the state the login sent.
      final Uri redirectUri =
          Uri.parse(url.queryParameters['redirect_uri']!);
      final HttpClient httpClient = HttpClient();
      try {
        final HttpClientRequest request = await httpClient.getUrl(
          redirectUri.replace(
            queryParameters: <String, String>{
              'code': 'auth-code',
              'state': url.queryParameters['state']!,
            },
          ),
        );
        final HttpClientResponse response = await request.close();
        await response.drain<void>();
      } finally {
        httpClient.close();
      }
      await adapter.completeOAuthLogin();
      expect(await adapter.isLoggedIn, isTrue);
      expect(
        await store.readToken('reddit'),
        testAccessToken,
      );
      expect(
        await store.readValue('reddit_refresh_token'),
        testRefreshToken,
      );
      final RedditUser me = await adapter.fetchMe();
      expect(me.name, 'testuser');
      expect(me.linkKarma, 100);
    });

    test('completeOAuthLoginWithCode works with a pasted code',
        () async {
      final FakeAccountStore store = FakeAccountStore();
      final ScriptedTransport transport = ScriptedTransport();
      final RedditAdapter adapter = RedditAdapter(
        client: RedditClient(httpClient: transport.client),
        accountStore: store,
      );
      await adapter.setClientId(testClientId);
      await adapter.beginOAuthLogin();
      await adapter.completeOAuthLoginWithCode('pasted-code');
      expect(await adapter.isLoggedIn, isTrue);
    });

    test('completeOAuthLogin without begin throws', () async {
      final RedditAdapter adapter = RedditAdapter(
        client: RedditClient(
          httpClient: ScriptedTransport().client,
        ),
        accountStore: FakeAccountStore(),
      );
      await expectLater(
        adapter.completeOAuthLogin(),
        throwsA(isA<RedditApiException>()),
      );
    });
  });

  group('Reddit feeds', () {
    test('logged-in timeline is /best, mapped to Posts', () async {
      final FakeAccountStore store = FakeAccountStore();
      final ScriptedTransport transport = ScriptedTransport();
      final RedditAdapter adapter =
          await loggedInAdapter(store, transport);
      final List<Post> posts = await adapter.fetchTimeline(limit: 2);
      expect(posts, hasLength(2));
      expect(posts.first.id, 'reddit:t3_abc123');
      expect(posts.first.platformId, 'reddit');
      expect(posts.first.authorName, 'testuser');
      expect(posts.first.authorHandle, 'u/testuser');
      expect(posts.first.text, 'Test Post');
      expect(posts.first.likeCount, 42);
      expect(posts.first.replyCount, 7);
      expect(
        transport.requests.any((http.Request r) =>
            r.url.host == 'oauth.reddit.com' && r.url.path == '/best'),
        isTrue,
      );
    });

    test('timeline maps selftext after the title', () async {
      final FakeAccountStore store = FakeAccountStore();
      final ScriptedTransport transport = ScriptedTransport();
      final RedditAdapter adapter =
          await loggedInAdapter(store, transport);
      final List<Post> posts = await adapter.fetchTimeline(limit: 2);
      expect(posts.first.text, 'Test Post');
    });

    test('subreddit feed parses hot/new and cleans r/ prefix',
        () async {
      final FakeAccountStore store = FakeAccountStore();
      final ScriptedTransport transport = ScriptedTransport();
      final RedditAdapter adapter =
          await loggedInAdapter(store, transport);
      final List<RedditPost> hot =
          await adapter.fetchSubreddit('r/flutter', sort: 'hot');
      expect(hot, hasLength(1));
      expect(hot.first.title, 'Test Post');
      final List<RedditPost> fresh =
          await adapter.fetchSubreddit('flutter', sort: 'new');
      expect(fresh, hasLength(1));
      await expectLater(
        adapter.fetchSubreddit('flutter', sort: 'bogus'),
        throwsA(isA<RedditApiException>()),
      );
    });

    test('subreddit about returns subscriber count', () async {
      final FakeAccountStore store = FakeAccountStore();
      final ScriptedTransport transport = ScriptedTransport();
      final RedditAdapter adapter =
          await loggedInAdapter(store, transport);
      final RedditSubreddit about =
          await adapter.fetchSubredditAbout('flutter');
      expect(about.name, 'flutter');
      expect(about.subscribers, 123456);
      expect(about.subscribed, isTrue);
    });

    test('fetchPost returns one post by fullname', () async {
      final FakeAccountStore store = FakeAccountStore();
      final ScriptedTransport transport = ScriptedTransport();
      final RedditAdapter adapter =
          await loggedInAdapter(store, transport);
      final RedditPost? post = await adapter.fetchPost('t3_abc123');
      expect(post, isNotNull);
      expect(post!.title, 'Test Post');
    });
  });

  group('Reddit guest mode', () {
    test('guest timeline uses the app-only token', () async {
      final FakeAccountStore store = FakeAccountStore();
      final ScriptedTransport transport = ScriptedTransport();
      final RedditAdapter adapter = RedditAdapter(
        client: RedditClient(httpClient: transport.client),
        accountStore: store,
      );
      await adapter.setClientId(testClientId);
      expect(await adapter.isLoggedIn, isFalse);
      final List<Post> posts = await adapter.fetchTimeline();
      expect(posts, hasLength(1));
      expect(posts.first.text, 'Popular Post');
      // The client credentials grant ran first.
      expect(
        transport.requests.any((http.Request r) =>
            r.url.path == '/api/v1/access_token' &&
            r.body.contains('grant_type=client_credentials')),
        isTrue,
      );
      // The feed call carried the app-only token.
      final http.Request feedRequest = transport.requests.lastWhere(
        (http.Request r) => r.url.path == '/r/popular/hot',
      );
      expect(
        feedRequest.headers['Authorization'],
        'Bearer $testAppOnlyToken',
      );
      // No user token was stored.
      expect(await store.readToken('reddit'), isNull);
    });

    test('guest timeline without a client ID uses public JSON',
        () async {
      final FakeAccountStore store = FakeAccountStore();
      final ScriptedTransport transport = ScriptedTransport();
      final RedditAdapter adapter = RedditAdapter(
        client: RedditClient(httpClient: transport.client),
        accountStore: store,
      );
      final List<Post> posts = await adapter.fetchTimeline();
      expect(posts, hasLength(1));
      expect(posts.first.text, 'Public Popular Post');
      expect(
        transport.requests.any((http.Request r) =>
            r.url.host == 'www.reddit.com' &&
            r.url.path == '/r/popular/hot.json'),
        isTrue,
      );
    });

    test('guest subreddit read works without login', () async {
      final FakeAccountStore store = FakeAccountStore();
      final ScriptedTransport transport = ScriptedTransport();
      final RedditAdapter adapter = RedditAdapter(
        client: RedditClient(httpClient: transport.client),
        accountStore: store,
      );
      final List<RedditPost> posts =
          await adapter.fetchSubreddit('flutter');
      expect(posts, hasLength(1));
      final List<RedditComment> comments =
          await adapter.fetchPostComments(
        subreddit: 'flutter',
        postId: 'abc123',
      );
      expect(comments, hasLength(1));
      expect(comments.first.body, 'Top comment');
      expect(comments.first.replies, hasLength(1));
      expect(comments.first.replies.first.body, 'Nested reply');
    });

    test('guest post lookup falls back to public comments JSON',
        () async {
      final FakeAccountStore store = FakeAccountStore();
      final ScriptedTransport transport = ScriptedTransport();
      final RedditAdapter adapter = RedditAdapter(
        client: RedditClient(httpClient: transport.client),
        accountStore: store,
      );
      final RedditPost? post = await adapter.fetchPost('abc123');
      expect(post, isNotNull);
      expect(post!.title, 'Test Post');
    });
  });

  group('Reddit actions', () {
    test('submit text and link posts', () async {
      final FakeAccountStore store = FakeAccountStore();
      final ScriptedTransport transport = ScriptedTransport();
      final RedditAdapter adapter =
          await loggedInAdapter(store, transport);
      final String name = await adapter.submitTextPost(
        subreddit: 'flutter',
        title: 'Hello',
        text: 'World',
      );
      expect(name, 't3_newpost');
      final http.Request submitRequest = transport.requests.lastWhere(
        (http.Request r) => r.url.path == '/api/submit',
      );
      expect(submitRequest.body, contains('kind=self'));
      expect(submitRequest.body, contains('sr=flutter'));
      final String linkName = await adapter.submitLinkPost(
        subreddit: 'flutter',
        title: 'Link',
        url: 'https://example.com',
      );
      expect(linkName, 't3_newpost');
      await expectLater(
        adapter.submitLinkPost(
          subreddit: 'flutter',
          title: 'No URL',
          url: '  ',
        ),
        throwsA(isA<RedditApiException>()),
      );
    });

    test('vote sends the right direction', () async {
      final FakeAccountStore store = FakeAccountStore();
      final ScriptedTransport transport = ScriptedTransport();
      final RedditAdapter adapter =
          await loggedInAdapter(store, transport);
      await adapter.upvote('t3_abc123');
      await adapter.downvote('t3_abc123');
      await adapter.clearVote('t3_abc123');
      final List<http.Request> votes = transport.requests
          .where((http.Request r) => r.url.path == '/api/vote')
          .toList();
      expect(votes, hasLength(3));
      expect(votes[0].body, contains('dir=1'));
      expect(votes[1].body, contains('dir=-1'));
      expect(votes[2].body, contains('dir=0'));
      expect(votes[0].body, contains('id=t3_abc123'));
    });

    test('comment posts and returns the created comment', () async {
      final FakeAccountStore store = FakeAccountStore();
      final ScriptedTransport transport = ScriptedTransport();
      final RedditAdapter adapter =
          await loggedInAdapter(store, transport);
      final RedditComment created = await adapter.postComment(
        thingId: 't3_abc123',
        text: 'Fresh comment',
      );
      expect(created.id, 'c9');
      expect(created.body, 'Fresh comment');
      await expectLater(
        adapter.postComment(thingId: 't3_abc123', text: '  '),
        throwsA(isA<RedditApiException>()),
      );
    });

    test('save, unsave, subscribe, unsubscribe', () async {
      final FakeAccountStore store = FakeAccountStore();
      final ScriptedTransport transport = ScriptedTransport();
      final RedditAdapter adapter =
          await loggedInAdapter(store, transport);
      await adapter.savePost('t3_abc123');
      await adapter.unsavePost('t3_abc123');
      await adapter.subscribeToSubreddit('flutter');
      await adapter.unsubscribeFromSubreddit('flutter');
      final List<String> paths = transport.requests
          .map((http.Request r) => r.url.path)
          .toList();
      expect(paths, contains('/api/save'));
      expect(paths, contains('/api/unsave'));
      expect(
        paths.where((String p) => p == '/api/subscribe').length,
        2,
      );
      final http.Request subRequest = transport.requests.lastWhere(
        (http.Request r) => r.url.path == '/api/subscribe',
      );
      expect(subRequest.body, contains('action=unsub'));
      expect(subRequest.body, contains('sr_name=flutter'));
    });

    test('my subreddits, inbox, saved and upvoted', () async {
      final FakeAccountStore store = FakeAccountStore();
      final ScriptedTransport transport = ScriptedTransport();
      final RedditAdapter adapter =
          await loggedInAdapter(store, transport);
      final List<RedditSubreddit> mine =
          await adapter.fetchMySubreddits();
      expect(mine.map((RedditSubreddit s) => s.name),
          <String>['flutter', 'dart']);
      final List<RedditMessage> inbox = await adapter.fetchInbox();
      expect(inbox, hasLength(2));
      expect(inbox.first.subject, 'comment reply');
      expect(inbox.first.isNew, isTrue);
      expect(inbox.last.subject, 'Private message');
      final List<RedditPost> saved = await adapter.fetchSaved();
      expect(saved, hasLength(1));
      expect(saved.first.saved, isTrue);
      final List<RedditPost> upvoted = await adapter.fetchUpvoted();
      expect(upvoted, hasLength(1));
      expect(upvoted.first.likes, isTrue);
    });

    test('search posts and subreddits', () async {
      final FakeAccountStore store = FakeAccountStore();
      final ScriptedTransport transport = ScriptedTransport();
      final RedditAdapter adapter =
          await loggedInAdapter(store, transport);
      final List<RedditPost> posts =
          await adapter.searchPosts('flutter');
      expect(posts, hasLength(1));
      expect(posts.first.title, 'Search Hit');
      final List<RedditSubreddit> subs =
          await adapter.searchSubreddits('flutter');
      expect(subs, hasLength(1));
      expect(subs.first.name, 'flutter');
      await expectLater(
        adapter.searchPosts('  '),
        throwsA(isA<RedditApiException>()),
      );
    });
  });

  group('Reddit auth edge cases', () {
    test('401 refreshes the token once and retries', () async {
      final FakeAccountStore store = FakeAccountStore();
      final ScriptedTransport transport =
          ScriptedTransport(expireOnce: true);
      final RedditAdapter adapter =
          await loggedInAdapter(store, transport);
      final List<Post> posts = await adapter.fetchTimeline(limit: 2);
      expect(posts, hasLength(2));
      // The refreshed token was persisted.
      expect(
        await store.readToken('reddit'),
        'refreshed-access-token',
      );
      expect(
        transport.requests.any((http.Request r) =>
            r.url.path == '/api/v1/access_token' &&
            r.body.contains('grant_type=refresh_token')),
        isTrue,
      );
    });

    test('revoked refresh token surfaces an error', () async {
      final FakeAccountStore store = FakeAccountStore();
      final ScriptedTransport transport = ScriptedTransport(
        expireOnce: true,
        refreshFails: true,
      );
      final RedditAdapter adapter =
          await loggedInAdapter(store, transport);
      await expectLater(
        adapter.fetchTimeline(limit: 2),
        throwsA(isA<RedditApiException>()),
      );
    });

    test('actions without login throw NotLoggedIn', () async {
      final RedditAdapter adapter = RedditAdapter(
        client: RedditClient(
          httpClient: ScriptedTransport().client,
        ),
        accountStore: FakeAccountStore(),
      );
      expect(await adapter.isLoggedIn, isFalse);
      await expectLater(
        adapter.upvote('t3_abc123'),
        throwsA(isA<RedditNotLoggedInException>()),
      );
      await expectLater(
        adapter.postComment(thingId: 't3_abc123', text: 'hi'),
        throwsA(isA<RedditNotLoggedInException>()),
      );
      await expectLater(
        adapter.submitTextPost(
          subreddit: 'flutter',
          title: 'x',
          text: 'y',
        ),
        throwsA(isA<RedditNotLoggedInException>()),
      );
      await expectLater(
        adapter.savePost('t3_abc123'),
        throwsA(isA<RedditNotLoggedInException>()),
      );
      await expectLater(
        adapter.subscribeToSubreddit('flutter'),
        throwsA(isA<RedditNotLoggedInException>()),
      );
      await expectLater(
        adapter.fetchInbox(),
        throwsA(isA<RedditNotLoggedInException>()),
      );
      await expectLater(
        adapter.fetchMySubreddits(),
        throwsA(isA<RedditNotLoggedInException>()),
      );
    });

    test('logout clears tokens but keeps the client ID', () async {
      final FakeAccountStore store = FakeAccountStore();
      final ScriptedTransport transport = ScriptedTransport();
      final RedditAdapter adapter =
          await loggedInAdapter(store, transport);
      expect(await adapter.isLoggedIn, isTrue);
      await adapter.logout();
      expect(await adapter.isLoggedIn, isFalse);
      expect(await store.readToken('reddit'), isNull);
      expect(
        await store.readValue('reddit_refresh_token'),
        isNull,
      );
      expect(await adapter.clientId, testClientId);
      // Guest browsing still works after logout.
      final List<Post> posts = await adapter.fetchTimeline();
      expect(posts, hasLength(1));
      expect(posts.first.text, 'Popular Post');
    });

    test('requests carry the Reddit User-Agent header', () async {
      final FakeAccountStore store = FakeAccountStore();
      final ScriptedTransport transport = ScriptedTransport();
      final RedditAdapter adapter =
          await loggedInAdapter(store, transport);
      await adapter.fetchTimeline(limit: 1);
      expect(
        transport.requests.every((http.Request r) =>
            (r.headers['User-Agent'] ?? '').startsWith('Similar-X/')),
        isTrue,
      );
    });
  });
}
