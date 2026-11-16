// Threads adapter tests, driven by a scripted fake HTTP transport.
//
// No real Threads API, network or account is involved: [MockClient]
// answers the OAuth endpoints and graph.threads.net with canned
// JSON. The OAuth flow is exercised end to end (authorize URL ->
// code -> short-lived token -> long-lived token -> tokens stored),
// including the access-token refresh on a 401 and the guest
// requires-login behaviour. The loopback listener test uses real
// TCP on 127.0.0.1 only.
//
// What the official API cannot do is also tested by its absence:
// there is no like endpoint, so the adapter must not declare the
// `like` capability.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:similar_x/adapters/threads/threads_client.dart';
import 'package:similar_x/adapters/threads/threads_models.dart';
import 'package:similar_x/adapters/threads_adapter.dart';
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

const String testAppId = 'threads-app-id-123';
const String testAppSecret = 'threads-app-secret-abc';
const String testUserId = '987654321';
const String testShortToken = 'TH_SHORT_LIVED';
const String testLongToken = 'TH_LONG_LIVED';
const String testRefreshedToken = 'TH_REFRESHED';

Map<String, Object?> threadData({
  String id = '17896481123456789',
  String text = 'Hello Threads',
  String username = 'testuser',
  String mediaType = 'TEXT',
  String mediaProductType = 'THREADS',
  int likeCount = 0,
  int replyCount = 0,
  int repostCount = 0,
  bool isReply = false,
}) =>
    <String, Object?>{
      'id': id,
      'media_product_type': mediaProductType,
      'media_type': mediaType,
      'media_url': '',
      'permalink': 'https://www.threads.net/@$username/post/$id',
      'username': username,
      'text': text,
      'timestamp': '2026-11-16T10:00:00+00:00',
      'shortcode': 'AbCdEfGhIjK',
      'thumbnail_url': '',
      'is_quote_post': false,
      'is_reply': isReply,
      'has_replies': replyCount > 0,
      'hide_status': 'NOT_HIDDEN',
      'is_verified': false,
      'like_count': likeCount,
      'reply_count': replyCount,
      'repost_count': repostCount,
      'quote_count': 0,
    };

Map<String, Object?> userData() => <String, Object?>{
      'id': testUserId,
      'username': 'testuser',
      'name': 'Test User',
      'threads_profile_picture_url': 'https://example.com/pic.jpg',
      'threads_biography': 'Testing Threads.',
    };

http.Response jsonResponse(Object? body, [int status = 200]) =>
    http.Response(
      json.encode(body),
      status,
      headers: <String, String>{'content-type': 'application/json'},
    );

/// A fake Threads API. [onRequest] is called for every request so
/// tests can count calls and inspect bodies. [failFirstGet] makes
/// the first authenticated GET return 401 (refresh path).
/// [refreshFails] makes the refresh endpoint return 400 (revoked
/// token path).
MockClient fakeThreadsApi({
  void Function(http.Request request)? onRequest,
  bool failFirstGet = false,
  bool refreshFails = false,
}) {
  int getCount = 0;
  return MockClient((http.Request request) async {
    onRequest?.call(request);
    final Uri uri = request.url;
    final String path = uri.path;
    // OAuth token exchange (no bearer token).
    if (uri.host == 'graph.threads.net' &&
        path == '/oauth/access_token' &&
        request.method == 'POST') {
      return jsonResponse(<String, Object?>{
        'access_token': testShortToken,
        'user_id': testUserId,
        'expires_in': 3600,
      });
    }
    // Long-lived token exchange.
    if (uri.host == 'graph.threads.net' &&
        path == '/access_token' &&
        uri.queryParameters['grant_type'] == 'th_exchange_token') {
      return jsonResponse(<String, Object?>{
        'access_token': testLongToken,
        'token_type': 'Bearer',
        'expires_in': 5184000,
      });
    }
    // Token refresh.
    if (uri.host == 'graph.threads.net' &&
        path == '/refresh_access_token') {
      if (refreshFails) {
        return jsonResponse(<String, Object?>{
          'error': <String, Object?>{
            'message': 'Invalid OAuth access token.',
            'code': 190,
          },
        }, 400);
      }
      return jsonResponse(<String, Object?>{
        'access_token': testRefreshedToken,
        'token_type': 'Bearer',
        'expires_in': 5184000,
      });
    }
    // Authenticated API calls.
    if (uri.host == 'graph.threads.net' && path.startsWith('/v1.0/')) {
      getCount++;
      if (failFirstGet && getCount == 1) {
        return jsonResponse(<String, Object?>{
          'error': <String, Object?>{
            'message': 'Invalid OAuth access token.',
            'code': 190,
          },
        }, 401);
      }
      final String rest = path.substring('/v1.0/'.length);
      // Profile.
      if (rest == 'me' && request.method == 'GET') {
        return jsonResponse(userData());
      }
      // Own threads.
      if (rest == '$testUserId/threads' && request.method == 'GET') {
        return jsonResponse(<String, Object?>{
          'data': <Object?>[
            threadData(likeCount: 12, replyCount: 3, repostCount: 1),
            threadData(
              id: '17896481123456790',
              text: 'Second thread',
              likeCount: 5,
            ),
            <String, Object?>{'text': 'no id at all'},
          ],
        });
      }
      // Container creation.
      if (rest == '$testUserId/threads' && request.method == 'POST') {
        return jsonResponse(<String, Object?>{'id': 'creation-1'});
      }
      // Publish container.
      if (rest == '$testUserId/threads_publish' &&
          request.method == 'POST') {
        return jsonResponse(<String, Object?>{'id': '17896481123456791'});
      }
      // Mentions.
      if (rest == '$testUserId/mentions' && request.method == 'GET') {
        return jsonResponse(<String, Object?>{
          'data': <Object?>[
            threadData(
              id: '17896481123456792',
              text: '@testuser nice thread!',
              username: 'mentioner',
              isReply: true,
            ),
          ],
        });
      }
      // Account insights.
      if (rest == '$testUserId/threads_insights' &&
          request.method == 'GET') {
        return jsonResponse(<String, Object?>{
          'data': <Object?>[
            <String, Object?>{
              'name': 'views',
              'values': <Object?>[
                <String, Object?>{'value': 1234},
              ],
            },
            <String, Object?>{
              'name': 'likes',
              'values': <Object?>[
                <String, Object?>{'value': 56},
              ],
            },
            <String, Object?>{
              'name': 'followers_count',
              'values': <Object?>[
                <String, Object?>{'value': 789},
              ],
            },
          ],
        });
      }
      // Keyword search.
      if (rest == 'keyword_search' && request.method == 'GET') {
        return jsonResponse(<String, Object?>{
          'data': <Object?>[
            threadData(
              id: '17896481123456793',
              text: 'A thread about flutter',
              username: 'flutterfan',
            ),
          ],
        });
      }
      // Publishing limit.
      if (rest == 'threads_publishing_limit' &&
          request.method == 'GET') {
        return jsonResponse(<String, Object?>{
          'data': <Object?>[
            <String, Object?>{
              'quota_usage': 3,
              'reply_quota_usage': 5,
              'config': <String, Object?>{
                'quota_total': 250,
                'reply_quota_total': 1000,
                'quota_duration': 86400,
              },
            },
          ],
        });
      }
      // Container status (video processing).
      if (rest == 'creation-1' &&
          request.method == 'GET' &&
          uri.queryParameters['fields'] == 'status') {
        return jsonResponse(<String, Object?>{'status': 'FINISHED'});
      }
      // Single post.
      if (rest == '17896481123456789' && request.method == 'GET') {
        return jsonResponse(
          threadData(likeCount: 12, replyCount: 3, repostCount: 1),
        );
      }
      // Replies to a post.
      if (rest == '17896481123456789/replies' &&
          request.method == 'GET') {
        return jsonResponse(<String, Object?>{
          'data': <Object?>[
            threadData(
              id: '17896481123456794',
              text: 'A reply',
              username: 'replier',
              isReply: true,
            ),
          ],
        });
      }
      // Conversation tree.
      if (rest == '17896481123456789/conversation' &&
          request.method == 'GET') {
        return jsonResponse(<String, Object?>{
          'data': <Object?>[
            threadData(
              id: '17896481123456794',
              text: 'A reply',
              username: 'replier',
              isReply: true,
            ),
            threadData(
              id: '17896481123456795',
              text: 'A nested reply',
              username: 'nested',
              isReply: true,
            ),
          ],
        });
      }
      // Post insights.
      if (rest == '17896481123456789/insights' &&
          request.method == 'GET') {
        return jsonResponse(<String, Object?>{
          'data': <Object?>[
            <String, Object?>{
              'name': 'views',
              'values': <Object?>[
                <String, Object?>{'value': 100},
              ],
            },
            <String, Object?>{
              'name': 'likes',
              'values': <Object?>[
                <String, Object?>{'value': 12},
              ],
            },
            <String, Object?>{
              'name': 'replies',
              'values': <Object?>[
                <String, Object?>{'value': 3},
              ],
            },
            <String, Object?>{
              'name': 'reposts',
              'values': <Object?>[
                <String, Object?>{'value': 1},
              ],
            },
          ],
        });
      }
      // Repost.
      if (rest == '17896481123456789/repost' &&
          request.method == 'POST') {
        return jsonResponse(<String, Object?>{'id': '17896481123456796'});
      }
      // Hide / unhide a reply.
      if ((rest == '17896481123456794/hide' ||
              rest == '17896481123456794/unhide') &&
          request.method == 'POST') {
        return jsonResponse(<String, Object?>{'success': true});
      }
      // Delete a post.
      if (rest == '17896481123456789' && request.method == 'DELETE') {
        return jsonResponse(<String, Object?>{'success': true});
      }
      return http.Response('Not found: $path', 404);
    }
    return http.Response('Not found: ${uri.host}$path', 404);
  });
}

/// An adapter wired to the fake API, already logged in.
Future<ThreadsAdapter> loggedInAdapter({
  MockClient? client,
  FakeAccountStore? store,
}) async {
  final FakeAccountStore accountStore = store ?? FakeAccountStore();
  await accountStore.saveValue('threads_app_id', testAppId);
  await accountStore.saveValue('threads_app_secret', testAppSecret);
  await accountStore.saveToken('threads', testLongToken);
  await accountStore.saveValue('threads_user_id', testUserId);
  await accountStore.saveValue(
    'threads_token_expires_at',
    DateTime.now().add(const Duration(days: 60)).toIso8601String(),
  );
  final ThreadsClient threadsClient = ThreadsClient(
    httpClient: client ?? fakeThreadsApi(),
  );
  final ThreadsAdapter adapter = ThreadsAdapter(
    client: threadsClient,
    accountStore: accountStore,
  );
  return adapter;
}

void main() {
  group('ThreadsAdapter metadata', () {
    test('declares limited status, requires login, no like capability',
        () {
      final ThreadsAdapter adapter = ThreadsAdapter();
      expect(adapter.id, 'threads');
      expect(adapter.displayName, 'Threads');
      expect(adapter.status, PlatformStatus.limited);
      expect(adapter.requiresLogin, isTrue);
      expect(adapter.capabilities, contains(AdapterCapability.timeline));
      expect(adapter.capabilities, contains(AdapterCapability.post));
      expect(adapter.capabilities, contains(AdapterCapability.comment));
      expect(adapter.capabilities, contains(AdapterCapability.repost));
      expect(adapter.capabilities, contains(AdapterCapability.search));
      expect(
        adapter.capabilities,
        contains(AdapterCapability.notifications),
      );
      // The official Threads API has no like endpoint, so the
      // adapter must not claim it.
      expect(adapter.capabilities, isNot(contains(AdapterCapability.like)));
      expect(adapter.note, contains('no like endpoint'));
      expect(adapter.note, contains('no public timeline'));
    });
  });

  group('Threads OAuth login', () {
    test('authorize URL carries app id, scopes and state', () async {
      final ThreadsAdapter adapter = ThreadsAdapter(
        client: ThreadsClient(httpClient: fakeThreadsApi()),
        accountStore: FakeAccountStore(),
      );
      await adapter.setAppCredentials(
        appId: testAppId,
        appSecret: testAppSecret,
      );
      final Uri url = await adapter.beginOAuthLogin();
      expect(url.host, 'www.threads.net');
      expect(url.path, '/oauth/authorize');
      expect(url.queryParameters['client_id'], testAppId);
      expect(url.queryParameters['response_type'], 'code');
      expect(url.queryParameters['scope'], contains('threads_basic'));
      expect(
        url.queryParameters['scope'],
        contains('threads_content_publish'),
      );
      expect(url.queryParameters['state'], isNotEmpty);
      expect(url.queryParameters['redirect_uri'], startsWith('http://127.0.0.1'));
      await adapter.cancelOAuthLogin();
    });

    test('beginOAuthLogin without app credentials throws', () async {
      final ThreadsAdapter adapter = ThreadsAdapter(
        client: ThreadsClient(httpClient: fakeThreadsApi()),
        accountStore: FakeAccountStore(),
      );
      await expectLater(
        adapter.beginOAuthLogin(),
        throwsA(isA<ThreadsApiException>()),
      );
    });

    test('login() directs the user to beginOAuthLogin', () async {
      final ThreadsAdapter adapter = ThreadsAdapter(
        client: ThreadsClient(httpClient: fakeThreadsApi()),
        accountStore: FakeAccountStore(),
      );
      await expectLater(
        adapter.login(),
        throwsA(isA<ThreadsApiException>()),
      );
    });

    test('completeOAuthLoginWithCode stores the long-lived token',
        () async {
      final FakeAccountStore store = FakeAccountStore();
      final ThreadsAdapter adapter = ThreadsAdapter(
        client: ThreadsClient(httpClient: fakeThreadsApi()),
        accountStore: store,
      );
      await adapter.setAppCredentials(
        appId: testAppId,
        appSecret: testAppSecret,
      );
      await adapter.beginOAuthLogin();
      await adapter.completeOAuthLoginWithCode('AUTH_CODE');
      expect(await store.readToken('threads'), testLongToken);
      expect(await store.readValue('threads_user_id'), testUserId);
      expect(await adapter.isLoggedIn, isTrue);
    });

    test('loopback listener captures the code from a redirect', () async {
      final ThreadsLoopbackAuthListener listener =
          await ThreadsLoopbackAuthListener.start();
      final Uri redirect = Uri.parse(
        '${listener.redirectUri}/?code=LOOPBACK_CODE&state=abc',
      );
      final HttpClient httpClient = HttpClient();
      try {
        final HttpClientRequest request =
            await httpClient.getUrl(redirect);
        final HttpClientResponse response = await request.close();
        await response.drain<void>();
      } finally {
        httpClient.close();
      }
      expect(await listener.code, 'LOOPBACK_CODE');
      expect(listener.state, 'abc');
    });
  });

  group('Threads timeline and reads', () {
    test('fetchTimeline maps own threads to unified posts', () async {
      final ThreadsAdapter adapter = await loggedInAdapter();
      final List<Post> posts = await adapter.fetchTimeline(limit: 20);
      expect(posts.length, 2);
      expect(posts.first.id, 'threads:17896481123456789');
      expect(posts.first.platformId, 'threads');
      expect(posts.first.authorHandle, '@testuser');
      expect(posts.first.text, 'Hello Threads');
      expect(posts.first.likeCount, 12);
      expect(posts.first.replyCount, 3);
      expect(posts.first.repostCount, 1);
    });

    test('guest timeline is empty, never fake data', () async {
      final ThreadsAdapter adapter = ThreadsAdapter(
        client: ThreadsClient(httpClient: fakeThreadsApi()),
        accountStore: FakeAccountStore(),
      );
      expect(await adapter.isLoggedIn, isFalse);
      expect(await adapter.fetchTimeline(), isEmpty);
    });

    test('fetchMe returns the profile', () async {
      final ThreadsAdapter adapter = await loggedInAdapter();
      final ThreadsUser me = await adapter.fetchMe();
      expect(me.id, testUserId);
      expect(me.username, 'testuser');
      expect(me.name, 'Test User');
      expect(me.biography, 'Testing Threads.');
    });

    test('fetchThread returns one post by media id', () async {
      final ThreadsAdapter adapter = await loggedInAdapter();
      final ThreadsPost post =
          await adapter.fetchThread('17896481123456789');
      expect(post.id, '17896481123456789');
      expect(post.text, 'Hello Threads');
      expect(post.likeCount, 12);
    });

    test('fetchReplies and fetchConversation parse replies', () async {
      final ThreadsAdapter adapter = await loggedInAdapter();
      final List<ThreadsPost> replies =
          await adapter.fetchReplies('17896481123456789');
      expect(replies.length, 1);
      expect(replies.first.text, 'A reply');
      expect(replies.first.isReply, isTrue);
      final List<ThreadsPost> conversation =
          await adapter.fetchConversation('17896481123456789');
      expect(conversation.length, 2);
    });

    test('fetchMentions returns posts mentioning the account', () async {
      final ThreadsAdapter adapter = await loggedInAdapter();
      final List<ThreadsPost> mentions = await adapter.fetchMentions();
      expect(mentions.length, 1);
      expect(mentions.first.username, 'mentioner');
    });

    test('searchKeyword returns matching posts', () async {
      final ThreadsAdapter adapter = await loggedInAdapter();
      final List<ThreadsPost> results =
          await adapter.searchKeyword('flutter');
      expect(results.length, 1);
      expect(results.first.text, contains('flutter'));
    });

    test('searchKeyword with an empty query throws before any call',
        () async {
      int calls = 0;
      final ThreadsAdapter adapter = await loggedInAdapter(
        client: fakeThreadsApi(
          onRequest: (_) {
            calls++;
          },
        ),
      );
      await expectLater(
        adapter.searchKeyword('   '),
        throwsA(isA<ThreadsApiException>()),
      );
      // Only the isLoggedIn probe ran; no search request went out.
      expect(calls, 0);
    });
  });

  group('Threads publishing', () {
    test('postText creates a container then publishes it', () async {
      final List<http.Request> seen = <http.Request>[];
      final ThreadsAdapter adapter = await loggedInAdapter(
        client: fakeThreadsApi(
          onRequest: seen.add,
        ),
      );
      final String mediaId = await adapter.postText('Hello Threads');
      expect(mediaId, '17896481123456791');
      final http.Request containerCall = seen.firstWhere(
        (http.Request r) =>
            r.url.path == '/v1.0/$testUserId/threads' &&
            r.method == 'POST',
      );
      expect(containerCall.bodyFields['media_type'], 'TEXT');
      expect(containerCall.bodyFields['text'], 'Hello Threads');
      final http.Request publishCall = seen.firstWhere(
        (http.Request r) =>
            r.url.path == '/v1.0/$testUserId/threads_publish',
      );
      expect(publishCall.bodyFields['creation_id'], 'creation-1');
    });

    test('postText over 500 characters throws before any call', () async {
      int calls = 0;
      final ThreadsAdapter adapter = await loggedInAdapter(
        client: fakeThreadsApi(
          onRequest: (_) {
            calls++;
          },
        ),
      );
      await expectLater(
        adapter.postText('x' * 501),
        throwsA(isA<ThreadsApiException>()),
      );
      expect(calls, 0);
    });

    test('replyToThread sends reply_to_id', () async {
      final List<http.Request> seen = <http.Request>[];
      final ThreadsAdapter adapter = await loggedInAdapter(
        client: fakeThreadsApi(onRequest: seen.add),
      );
      await adapter.replyToThread(
        replyToId: '17896481123456789',
        text: 'A reply',
      );
      final http.Request containerCall = seen.firstWhere(
        (http.Request r) =>
            r.url.path == '/v1.0/$testUserId/threads' &&
            r.method == 'POST',
      );
      expect(
        containerCall.bodyFields['reply_to_id'],
        '17896481123456789',
      );
    });

    test('quoteThread sends quote_post_id', () async {
      final List<http.Request> seen = <http.Request>[];
      final ThreadsAdapter adapter = await loggedInAdapter(
        client: fakeThreadsApi(onRequest: seen.add),
      );
      await adapter.quoteThread(
        quotePostId: '17896481123456789',
        text: 'My take',
      );
      final http.Request containerCall = seen.firstWhere(
        (http.Request r) =>
            r.url.path == '/v1.0/$testUserId/threads' &&
            r.method == 'POST',
      );
      expect(
        containerCall.bodyFields['quote_post_id'],
        '17896481123456789',
      );
    });

    test('repostThread fires the repost endpoint', () async {
      final ThreadsAdapter adapter = await loggedInAdapter();
      final String repostId =
          await adapter.repostThread('17896481123456789');
      expect(repostId, '17896481123456796');
    });

    test('postImage sends IMAGE container with the URL', () async {
      final List<http.Request> seen = <http.Request>[];
      final ThreadsAdapter adapter = await loggedInAdapter(
        client: fakeThreadsApi(onRequest: seen.add),
      );
      await adapter.postImage(
        'With a picture',
        imageUrl: 'https://example.com/pic.jpg',
      );
      final http.Request containerCall = seen.firstWhere(
        (http.Request r) =>
            r.url.path == '/v1.0/$testUserId/threads' &&
            r.method == 'POST',
      );
      expect(containerCall.bodyFields['media_type'], 'IMAGE');
      expect(
        containerCall.bodyFields['image_url'],
        'https://example.com/pic.jpg',
      );
    });

    test('postVideo waits for processing then publishes', () async {
      final ThreadsAdapter adapter = await loggedInAdapter();
      final String mediaId = await adapter.postVideo(
        'With a video',
        videoUrl: 'https://example.com/video.mp4',
      );
      expect(mediaId, '17896481123456791');
    });

    test('postCarousel sends CAROUSEL container with children', () async {
      final List<http.Request> seen = <http.Request>[];
      final ThreadsAdapter adapter = await loggedInAdapter(
        client: fakeThreadsApi(onRequest: seen.add),
      );
      final String mediaId = await adapter.postCarousel(
        'A carousel',
        items: <Map<String, String>>[
          <String, String>{'image_url': 'https://example.com/1.jpg'},
          <String, String>{'image_url': 'https://example.com/2.jpg'},
        ],
      );
      expect(mediaId, '17896481123456791');
      final http.Request containerCall = seen.firstWhere(
        (http.Request r) =>
            r.url.path == '/v1.0/$testUserId/threads' &&
            r.method == 'POST',
      );
      expect(containerCall.bodyFields['media_type'], 'CAROUSEL');
      final List<Object?> children = json.decode(
        containerCall.bodyFields['children']!,
      ) as List<Object?>;
      expect(children.length, 2);
    });

    test('postCarousel rejects fewer than 2 items', () async {
      final ThreadsAdapter adapter = await loggedInAdapter();
      await expectLater(
        adapter.postCarousel(
          'Too few',
          items: <Map<String, String>>[
            <String, String>{'image_url': 'https://example.com/1.jpg'},
          ],
        ),
        throwsA(isA<ThreadsApiException>()),
      );
    });

    test('hide and unhide a reply', () async {
      final ThreadsAdapter adapter = await loggedInAdapter();
      await adapter.hideReply('17896481123456794');
      await adapter.unhideReply('17896481123456794');
    });

    test('deleteThread deletes a post', () async {
      final ThreadsAdapter adapter = await loggedInAdapter();
      await adapter.deleteThread('17896481123456789');
    });
  });

  group('Threads insights and quota', () {
    test('fetchThreadInsights parses views, likes, replies, reposts',
        () async {
      final ThreadsAdapter adapter = await loggedInAdapter();
      final ThreadsInsights insights =
          await adapter.fetchThreadInsights('17896481123456789');
      expect(insights.views, 100);
      expect(insights.likes, 12);
      expect(insights.replies, 3);
      expect(insights.reposts, 1);
    });

    test('fetchAccountInsights parses views, likes, followers', () async {
      final ThreadsAdapter adapter = await loggedInAdapter();
      final ThreadsInsights insights =
          await adapter.fetchAccountInsights();
      expect(insights.views, 1234);
      expect(insights.likes, 56);
      expect(insights.followersCount, 789);
    });

    test('fetchPublishingLimit parses quota usage', () async {
      final ThreadsAdapter adapter = await loggedInAdapter();
      final ThreadsPublishingLimit limit =
          await adapter.fetchPublishingLimit();
      expect(limit.quotaUsage, 3);
      expect(limit.replyQuotaUsage, 5);
      expect(limit.quotaTotal, 250);
      expect(limit.replyQuotaTotal, 1000);
      expect(limit.postsRemaining, 247);
      expect(limit.repliesRemaining, 995);
    });
  });

  group('Threads session handling', () {
    test('401 refreshes the token once and retries', () async {
      final FakeAccountStore store = FakeAccountStore();
      final ThreadsAdapter adapter = await loggedInAdapter(
        client: fakeThreadsApi(failFirstGet: true),
        store: store,
      );
      final List<Post> posts = await adapter.fetchTimeline();
      expect(posts.length, 2);
      expect(await store.readToken('threads'), testRefreshedToken);
    });

    test('revoked token fails refresh and asks to log in again', () async {
      final ThreadsAdapter adapter = await loggedInAdapter(
        client: fakeThreadsApi(
          failFirstGet: true,
          refreshFails: true,
        ),
      );
      await expectLater(
        adapter.fetchTimeline(),
        throwsA(isA<ThreadsApiException>()),
      );
    });

    test('actions without login throw ThreadsNotLoggedInException',
        () async {
      final ThreadsAdapter adapter = ThreadsAdapter(
        client: ThreadsClient(httpClient: fakeThreadsApi()),
        accountStore: FakeAccountStore(),
      );
      await expectLater(
        adapter.postText('Hello'),
        throwsA(isA<ThreadsNotLoggedInException>()),
      );
      await expectLater(
        adapter.searchKeyword('flutter'),
        throwsA(isA<ThreadsNotLoggedInException>()),
      );
      await expectLater(
        adapter.fetchMentions(),
        throwsA(isA<ThreadsNotLoggedInException>()),
      );
    });

    test('proactive refresh when the token expires within 7 days',
        () async {
      final FakeAccountStore store = FakeAccountStore();
      await store.saveValue('threads_app_id', testAppId);
      await store.saveValue('threads_app_secret', testAppSecret);
      await store.saveToken('threads', testLongToken);
      await store.saveValue('threads_user_id', testUserId);
      await store.saveValue(
        'threads_token_expires_at',
        DateTime.now().add(const Duration(days: 3)).toIso8601String(),
      );
      final ThreadsAdapter adapter = ThreadsAdapter(
        client: ThreadsClient(httpClient: fakeThreadsApi()),
        accountStore: store,
      );
      expect(await adapter.isLoggedIn, isTrue);
      expect(await store.readToken('threads'), testRefreshedToken);
    });

    test('logout deletes the token but keeps app credentials', () async {
      final FakeAccountStore store = FakeAccountStore();
      final ThreadsAdapter adapter =
          await loggedInAdapter(store: store);
      expect(await adapter.isLoggedIn, isTrue);
      await adapter.logout();
      expect(await adapter.isLoggedIn, isFalse);
      expect(await store.readToken('threads'), isNull);
      expect(await store.readValue('threads_app_id'), testAppId);
      expect(await store.readValue('threads_app_secret'), testAppSecret);
    });
  });

  group('Threads models', () {
    test('malformed posts are filtered, not fatal', () {
      final ThreadsPost post = ThreadsPost.fromJson(
        <String, dynamic>{'text': 'no id'},
      );
      expect(post.isValid, isFalse);
      final ThreadsPost good = ThreadsPost.fromJson(threadData());
      expect(good.isValid, isTrue);
      expect(good.isRepost, isFalse);
      final ThreadsPost repost = ThreadsPost.fromJson(
        threadData(mediaProductType: 'REPOST_FACADE'),
      );
      expect(repost.isRepost, isTrue);
    });

    test('insights parse missing metrics as zero', () {
      final ThreadsInsights insights =
          ThreadsInsights.fromJson(<String, dynamic>{
        'data': <Object?>[
          <String, Object?>{
            'name': 'views',
            'values': <Object?>[
              <String, Object?>{'value': 42},
            ],
          },
        ],
      });
      expect(insights.views, 42);
      expect(insights.likes, 0);
    });
  });
}
