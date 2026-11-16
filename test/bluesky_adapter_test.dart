// Bluesky adapter tests, driven by a scripted fake HTTP transport.
//
// No real PDS, AppView, network or account is involved: [MockClient]
// answers AT Protocol calls with canned JSON. The session flow is
// exercised end to end (createSession -> tokens stored -> profile),
// including the access-JWT refresh on an ExpiredToken 401.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:similar_x/adapters/bluesky/bluesky_client.dart';
import 'package:similar_x/adapters/bluesky/bluesky_models.dart';
import 'package:similar_x/adapters/bluesky_adapter.dart';
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

const String aliceDid = 'did:plc:alice123';
const String aliceHandle = 'alice.bsky.social';
const String alicePostUri =
    'at://did:plc:alice123/app.bsky.feed.post/3l100';
const String alicePostCid = 'bafy100';

Map<String, Object?> profileJson({
  String did = aliceDid,
  String handle = aliceHandle,
  String displayName = 'Alice',
}) =>
    <String, Object?>{
      'did': did,
      'handle': handle,
      'displayName': displayName,
      'avatar': 'https://cdn.bsky.app/avatar.png',
      'description': 'Hello Bluesky',
      'followersCount': 10,
      'followsCount': 5,
      'postsCount': 42,
      'indexedAt': '2026-11-16T12:00:00.000Z',
    };

Map<String, Object?> postViewJson({
  String uri = alicePostUri,
  String cid = alicePostCid,
  Map<String, Object?>? author,
  String text = 'Hello Bluesky',
  int likes = 5,
  int reposts = 2,
  int replies = 1,
  String? likeUri,
  String? repostUri,
  Map<String, Object?>? reply,
}) =>
    <String, Object?>{
      'uri': uri,
      'cid': cid,
      'author': author ?? profileJson(),
      'record': <String, Object?>{
        r'$type': 'app.bsky.feed.post',
        'text': text,
        'createdAt': '2026-11-16T12:00:00.000Z',
        ...?reply == null ? null : <String, Object?>{'reply': reply},
      },
      'replyCount': replies,
      'repostCount': reposts,
      'likeCount': likes,
      'quoteCount': 0,
      'indexedAt': '2026-11-16T12:00:00.000Z',
      'viewer': <String, Object?>{
        'like': likeUri,
        'repost': repostUri,
        'threadMuted': false,
      },
    };

Map<String, Object?> feedViewJson({
  Map<String, Object?>? post,
  Map<String, Object?>? repostedBy,
}) =>
    <String, Object?>{
      'post': post ?? postViewJson(),
      ...?repostedBy == null
          ? null
          : <String, Object?>{
              'reason': <String, Object?>{
                r'$type': 'app.bsky.feed.defs#reasonRepost',
                'by': repostedBy,
                'indexedAt': '2026-11-16T12:00:00.000Z',
              },
            },
    };

Map<String, Object?> threadViewJson({
  Map<String, Object?>? post,
  Map<String, Object?>? parent,
  List<Object?> replies = const <Object?>[],
}) =>
    <String, Object?>{
      r'$type': 'app.bsky.feed.defs#threadViewPost',
      'post': post ?? postViewJson(),
      ...?parent == null ? null : <String, Object?>{'parent': parent},
      'replies': replies,
    };

/// A fake Bluesky: bsky.social answers PDS calls (sessions and
/// records), public.api.bsky.app answers AppView calls (feeds,
/// profiles, search, threads, notifications), and offline.invalid
/// throws [http.ClientException] to simulate an unreachable service.
class FakeBlueskyServer {
  FakeBlueskyServer() {
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

    Map<String, dynamic> bodyJson() {
      try {
        return jsonDecode(request.body) as Map<String, dynamic>;
      } catch (_) {
        return <String, dynamic>{};
      }
    }

    if (host == 'bsky.social') {
      if (method == 'POST' &&
          path == '/xrpc/com.atproto.server.createSession') {
        final Map<String, dynamic> body = bodyJson();
        if (body['identifier'] == aliceHandle &&
            body['password'] == 'app-password-1234') {
          return _json(<String, Object?>{
            'did': aliceDid,
            'handle': aliceHandle,
            'accessJwt': 'test-access-jwt',
            'refreshJwt': 'test-refresh-jwt',
            'active': true,
          });
        }
        return _json(
          <String, Object?>{
            'error': 'InvalidPassword',
            'message': 'Invalid password',
          },
          status: 400,
        );
      }
      if (method == 'POST' &&
          path == '/xrpc/com.atproto.server.refreshSession') {
        final String? auth = request.headers['Authorization'];
        if (auth == 'Bearer test-refresh-jwt') {
          return _json(<String, Object?>{
            'did': aliceDid,
            'handle': aliceHandle,
            'accessJwt': 'new-access-jwt',
            'refreshJwt': 'new-refresh-jwt',
            'active': true,
          });
        }
        return _json(
          <String, Object?>{
            'error': 'ExpiredToken',
            'message': 'Token has expired',
          },
          status: 401,
        );
      }
      if (method == 'POST' &&
          path == '/xrpc/com.atproto.repo.createRecord') {
        final Map<String, dynamic> body = bodyJson();
        final String collection = (body['collection'] as String?) ?? '';
        const Map<String, String> rkeys = <String, String>{
          'app.bsky.feed.post': '3lnewpost',
          'app.bsky.feed.like': '3llike',
          'app.bsky.feed.repost': '3lrepost',
          'app.bsky.graph.follow': '3lfollow',
        };
        final String rkey = rkeys[collection] ?? '3lunknown';
        return _json(<String, Object?>{
          'uri': 'at://$aliceDid/$collection/$rkey',
          'cid': 'bafy$rkey',
        });
      }
      if (method == 'POST' &&
          path == '/xrpc/com.atproto.repo.deleteRecord') {
        return _json(<String, Object?>{});
      }
    }

    if (host == 'public.api.bsky.app') {
      if (method == 'GET' && path == '/xrpc/app.bsky.feed.getTimeline') {
        final String? auth = request.headers['Authorization'];
        if (auth == 'Bearer expired-jwt') {
          return _json(
            <String, Object?>{
              'error': 'ExpiredToken',
              'message': 'Token has expired',
            },
            status: 401,
          );
        }
        if (auth == null || auth.isEmpty) {
          return _json(
            <String, Object?>{
              'error': 'AuthenticationRequired',
              'message': 'Authentication required',
            },
            status: 401,
          );
        }
        return _json(<String, Object?>{
          'feed': <Object?>[
            feedViewJson(),
            feedViewJson(
              post: postViewJson(
                uri:
                    'at://did:plc:carol123/app.bsky.feed.post/3l101',
                cid: 'bafy101',
                author: profileJson(
                  did: 'did:plc:carol123',
                  handle: 'carol.bsky.social',
                  displayName: 'Carol',
                ),
                text: 'Original post',
              ),
              repostedBy: profileJson(
                did: 'did:plc:bob123',
                handle: 'bob.bsky.social',
                displayName: 'Bob',
              ),
            ),
          ],
        });
      }
      if (method == 'GET' && path == '/xrpc/app.bsky.feed.getFeed') {
        return _json(<String, Object?>{
          'feed': <Object?>[
            feedViewJson(
              post: postViewJson(
                uri: 'at://did:plc:dave123/app.bsky.feed.post/3l300',
                cid: 'bafy300',
                author: profileJson(
                  did: 'did:plc:dave123',
                  handle: 'dave.bsky.social',
                  displayName: 'Dave',
                ),
                text: 'Discover post',
              ),
            ),
          ],
        });
      }
      if (method == 'GET' &&
          path == '/xrpc/app.bsky.feed.getAuthorFeed') {
        return _json(<String, Object?>{
          'feed': <Object?>[feedViewJson()],
        });
      }
      if (method == 'GET' && path == '/xrpc/app.bsky.actor.getProfile') {
        final String actor =
            request.url.queryParameters['actor'] ?? aliceHandle;
        return _json(profileJson(handle: actor));
      }
      if (method == 'GET' &&
          path == '/xrpc/app.bsky.feed.getPostThread') {
        return _json(<String, Object?>{
          'thread': threadViewJson(
            parent: threadViewJson(
              post: postViewJson(
                uri: 'at://did:plc:carol123/app.bsky.feed.post/3l99',
                cid: 'bafy99',
                author: profileJson(
                  did: 'did:plc:carol123',
                  handle: 'carol.bsky.social',
                  displayName: 'Carol',
                ),
                text: 'Thread root',
              ),
            ),
            replies: <Object?>[
              threadViewJson(
                post: postViewJson(
                  uri:
                      'at://did:plc:bob123/app.bsky.feed.post/3l200',
                  cid: 'bafy200',
                  author: profileJson(
                    did: 'did:plc:bob123',
                    handle: 'bob.bsky.social',
                    displayName: 'Bob',
                  ),
                  text: 'A reply',
                  reply: <String, Object?>{
                    'root': <String, String>{
                      'uri':
                          'at://did:plc:carol123/app.bsky.feed.post/3l99',
                      'cid': 'bafy99',
                    },
                    'parent': <String, String>{
                      'uri': alicePostUri,
                      'cid': alicePostCid,
                    },
                  },
                ),
              ),
              // A blocked reply: skipped, not an error.
              <String, Object?>{
                r'$type': 'app.bsky.feed.defs#blockedPost',
                'uri': 'at://did:plc:eve123/app.bsky.feed.post/3l201',
                'blocked': true,
              },
            ],
          ),
        });
      }
      if (method == 'GET' &&
          path == '/xrpc/app.bsky.notification.listNotifications') {
        return _json(<String, Object?>{
          'notifications': <Object?>[
            <String, Object?>{
              'uri': 'at://did:plc:alice123/app.bsky.notification/1',
              'cid': 'bafyn1',
              'author': profileJson(
                did: 'did:plc:bob123',
                handle: 'bob.bsky.social',
                displayName: 'Bob',
              ),
              'reason': 'mention',
              'reasonSubject': alicePostUri,
              'record': <String, Object?>{
                r'$type': 'app.bsky.feed.post',
                'text': '@alice hi',
              },
              'isRead': false,
              'indexedAt': '2026-11-16T12:00:00.000Z',
            },
            <String, Object?>{
              'uri': 'at://did:plc:alice123/app.bsky.notification/2',
              'cid': 'bafyn2',
              'author': profileJson(
                did: 'did:plc:carol123',
                handle: 'carol.bsky.social',
                displayName: 'Carol',
              ),
              'reason': 'like',
              'reasonSubject': alicePostUri,
              'record': <String, Object?>{},
              'isRead': true,
              'indexedAt': '2026-11-16T12:00:00.000Z',
            },
          ],
        });
      }
      if (method == 'GET' && path == '/xrpc/app.bsky.actor.searchActors') {
        return _json(<String, Object?>{
          'actors': <Object?>[profileJson()],
        });
      }
      if (method == 'GET' && path == '/xrpc/app.bsky.feed.searchPosts') {
        return _json(<String, Object?>{
          'posts': <Object?>[
            postViewJson(text: 'Found it'),
          ],
        });
      }
    }
    return _json(<String, Object?>{'error': 'not found'}, status: 404);
  }

  http.Response _json(Object? body, {int status = 200}) =>
      http.Response(jsonEncode(body), status, headers: <String, String>{
        'content-type': 'application/json',
      });
}

void main() {
  late FakeBlueskyServer server;
  late FakeAccountStore store;
  late BlueskyAdapter adapter;

  setUp(() {
    server = FakeBlueskyServer();
    store = FakeAccountStore();
    adapter = BlueskyAdapter(
      client: BlueskyClient(
        service: 'bsky.social',
        httpClient: server.client,
      ),
      accountStore: store,
    );
  });

  Future<BlueskyProfile> logIn() async {
    return adapter.loginWithAppPassword(
      handle: aliceHandle,
      appPassword: 'app-password-1234',
    );
  }

  test('handles and services are normalized and validated', () {
    expect(normalizeBlueskyHandle('@Alice.Bsky.Social'), aliceHandle);
    expect(normalizeBlueskyHandle('did:plc:alice123'), 'did:plc:alice123');
    expect(
      () => normalizeBlueskyHandle('not a handle'),
      throwsA(isA<BlueskyApiException>()),
    );
    expect(() => normalizeBlueskyHandle(''), throwsA(isA<BlueskyApiException>()));
    expect(normalizeBlueskyService('https://bsky.social/'), 'bsky.social');
    expect(normalizeBlueskyService(''), blueskyDefaultService);
    expect(
      () => normalizeBlueskyService('not a host'),
      throwsA(isA<BlueskyApiException>()),
    );
    expect(atUriRkey('at://did:plc:alice123/app.bsky.feed.like/3llike'), '3llike');
    expect(atUriRepo('at://did:plc:alice123/app.bsky.feed.like/3llike'), 'did:plc:alice123');
  });

  test('login stores the session and returns the profile', () async {
    final BlueskyProfile profile = await logIn();
    expect(profile.handle, aliceHandle);
    expect(profile.displayName, 'Alice');
    expect(await adapter.isLoggedIn, isTrue);
    expect(await store.readToken('bluesky'), 'test-access-jwt');
    expect(
      await store.readValue('bluesky_refresh_jwt'),
      'test-refresh-jwt',
    );
    expect(await store.readValue('bluesky_handle'), aliceHandle);
    expect(await store.readValue('bluesky_did'), aliceDid);
    expect(adapter.status, PlatformStatus.ready);
    expect(adapter.requiresLogin, isFalse);
    final BlueskyProfile? account = await adapter.account;
    expect(account?.handle, aliceHandle);
  });

  test('wrong App Password throws', () async {
    await expectLater(
      adapter.loginWithAppPassword(
        handle: aliceHandle,
        appPassword: 'wrong-password',
      ),
      throwsA(isA<BlueskyApiException>()),
    );
    expect(await adapter.isLoggedIn, isFalse);
  });

  test('bad handle throws before any network call', () async {
    await expectLater(
      adapter.loginWithAppPassword(
        handle: 'not a handle',
        appPassword: 'app-password-1234',
      ),
      throwsA(isA<BlueskyApiException>()),
    );
    expect(server.sentRequests, isEmpty);
  });

  test('login() without credentials throws a clear error', () async {
    await expectLater(
      adapter.login(),
      throwsA(
        isA<BlueskyApiException>().having(
          (BlueskyApiException e) => e.message,
          'message',
          contains('loginWithAppPassword'),
        ),
      ),
    );
  });

  test('home timeline parses counts and repost reasons', () async {
    await logIn();
    final List<Post> posts = await adapter.fetchTimeline();
    expect(posts, hasLength(2));
    expect(posts[0].authorName, 'Alice');
    expect(posts[0].text, 'Hello Bluesky');
    expect(posts[0].likeCount, 5);
    expect(posts[0].repostCount, 2);
    expect(posts[0].replyCount, 1);
    expect(posts[0].platformId, 'bluesky');
    expect(posts[0].id, 'bluesky:$alicePostUri');
    // A repost shows the original post and its author.
    expect(posts[1].authorName, 'Carol');
    expect(posts[1].text, 'Original post');
  });

  test('guests get the Discover feed without logging in', () async {
    expect(await adapter.isLoggedIn, isFalse);
    final List<Post> posts = await adapter.fetchTimeline();
    expect(posts, hasLength(1));
    expect(posts[0].authorName, 'Dave');
    expect(posts[0].text, 'Discover post');
    final http.Request feedRequest = server.sentRequests.singleWhere(
      (http.Request r) => r.url.path == '/xrpc/app.bsky.feed.getFeed',
    );
    expect(
      feedRequest.url.queryParameters['feed'],
      blueskyDiscoverFeedUri,
    );
  });

  test('author feed and profile work for guests', () async {
    final List<BlueskyFeedView> feed =
        await adapter.fetchAuthorFeed(aliceHandle);
    expect(feed, hasLength(1));
    expect(feed[0].post.author.handle, aliceHandle);
    final BlueskyProfile profile =
        await adapter.fetchProfile(aliceHandle);
    expect(profile.displayName, 'Alice');
    expect(profile.followersCount, 10);
  });

  test('post sends the right record fields', () async {
    await logIn();
    final BlueskyPostRef ref =
        await adapter.postText('Hello Bluesky');
    expect(ref.uri, 'at://$aliceDid/app.bsky.feed.post/3lnewpost');
    expect(ref.cid, 'bafy3lnewpost');
    final http.Request createRequest = server.sentRequests.lastWhere(
      (http.Request r) =>
          r.url.path == '/xrpc/com.atproto.repo.createRecord',
    );
    final Map<String, dynamic> body =
        jsonDecode(createRequest.body) as Map<String, dynamic>;
    expect(body['repo'], aliceDid);
    expect(body['collection'], 'app.bsky.feed.post');
    final Map<String, dynamic> record =
        body['record'] as Map<String, dynamic>;
    expect(record[r'$type'], 'app.bsky.feed.post');
    expect(record['text'], 'Hello Bluesky');
    expect(record['createdAt'], isNotNull);
  });

  test('reply sends root and parent refs', () async {
    await logIn();
    final String rootUri =
        'at://did:plc:carol123/app.bsky.feed.post/3l99';
    final BlueskyPostRef ref = await adapter.reply(
      alicePostUri,
      alicePostCid,
      'Replying here',
      rootUri: rootUri,
      rootCid: 'bafy99',
    );
    expect(ref.uri, contains('app.bsky.feed.post'));
    final http.Request createRequest = server.sentRequests.lastWhere(
      (http.Request r) =>
          r.url.path == '/xrpc/com.atproto.repo.createRecord',
    );
    final Map<String, dynamic> body =
        jsonDecode(createRequest.body) as Map<String, dynamic>;
    final Map<String, dynamic> reply =
        (body['record'] as Map<String, dynamic>)['reply']
            as Map<String, dynamic>;
    expect((reply['root'] as Map<String, dynamic>)['uri'], rootUri);
    expect((reply['parent'] as Map<String, dynamic>)['uri'], alicePostUri);
  });

  test('like, unlike, repost and unrepost', () async {
    await logIn();
    final String likeUri = await adapter.likePost(
      alicePostUri,
      alicePostCid,
    );
    expect(likeUri, 'at://$aliceDid/app.bsky.feed.like/3llike');
    http.Request createRequest = server.sentRequests.lastWhere(
      (http.Request r) =>
          r.url.path == '/xrpc/com.atproto.repo.createRecord',
    );
    Map<String, dynamic> body =
        jsonDecode(createRequest.body) as Map<String, dynamic>;
    expect(body['collection'], 'app.bsky.feed.like');
    expect(
      (body['record'] as Map<String, dynamic>)['subject'],
      <String, String>{'uri': alicePostUri, 'cid': alicePostCid},
    );
    await adapter.unlikePost(likeUri);
    http.Request deleteRequest = server.sentRequests.lastWhere(
      (http.Request r) =>
          r.url.path == '/xrpc/com.atproto.repo.deleteRecord',
    );
    body = jsonDecode(deleteRequest.body) as Map<String, dynamic>;
    expect(body['collection'], 'app.bsky.feed.like');
    expect(body['rkey'], '3llike');
    expect(body['repo'], aliceDid);

    final String repostUri = await adapter.repostPost(
      alicePostUri,
      alicePostCid,
    );
    expect(repostUri, 'at://$aliceDid/app.bsky.feed.repost/3lrepost');
    await adapter.unrepostPost(repostUri);
    deleteRequest = server.sentRequests.lastWhere(
      (http.Request r) =>
          r.url.path == '/xrpc/com.atproto.repo.deleteRecord',
    );
    body = jsonDecode(deleteRequest.body) as Map<String, dynamic>;
    expect(body['collection'], 'app.bsky.feed.repost');
    expect(body['rkey'], '3lrepost');
  });

  test('thread parses parent, replies and skips blocked posts', () async {
    final BlueskyThreadPost thread =
        await adapter.fetchThread(alicePostUri);
    expect(thread.post.author.handle, aliceHandle);
    expect(thread.parent?.post.author.handle, 'carol.bsky.social');
    expect(thread.replies, hasLength(1));
    expect(thread.replies[0].post.author.handle, 'bob.bsky.social');
    expect(thread.replies[0].post.text, 'A reply');
    expect(thread.replies[0].post.replyTo?.rootUri,
        'at://did:plc:carol123/app.bsky.feed.post/3l99');
    expect(thread.replies[0].post.replyTo?.parentUri, alicePostUri);
  });

  test('notifications list mentions and likes', () async {
    await logIn();
    final List<BlueskyNotification> notes =
        await adapter.fetchNotifications();
    expect(notes, hasLength(2));
    expect(notes[0].reason, 'mention');
    expect(notes[0].author.name, 'Bob');
    expect(notes[0].postUri, alicePostUri);
    expect(notes[0].isRead, isFalse);
    expect(notes[1].reason, 'like');
    expect(notes[1].author.name, 'Carol');
    expect(notes[1].isRead, isTrue);
  });

  test('follow and unfollow use the follow record', () async {
    await logIn();
    final String followUri =
        await adapter.followAccount('did:plc:bob123');
    expect(
      followUri,
      'at://$aliceDid/app.bsky.graph.follow/3lfollow',
    );
    http.Request createRequest = server.sentRequests.lastWhere(
      (http.Request r) =>
          r.url.path == '/xrpc/com.atproto.repo.createRecord',
    );
    Map<String, dynamic> body =
        jsonDecode(createRequest.body) as Map<String, dynamic>;
    expect(body['collection'], 'app.bsky.graph.follow');
    expect(
      (body['record'] as Map<String, dynamic>)['subject'],
      'did:plc:bob123',
    );
    await adapter.unfollowAccount(followUri);
    final http.Request deleteRequest = server.sentRequests.lastWhere(
      (http.Request r) =>
          r.url.path == '/xrpc/com.atproto.repo.deleteRecord',
    );
    body = jsonDecode(deleteRequest.body) as Map<String, dynamic>;
    expect(body['collection'], 'app.bsky.graph.follow');
    expect(body['rkey'], '3lfollow');
  });

  test('search finds actors and posts', () async {
    final List<BlueskyProfile> actors =
        await adapter.searchActors('alice');
    expect(actors, hasLength(1));
    expect(actors[0].handle, aliceHandle);
    final List<BlueskyPost> posts =
        await adapter.searchPosts('found');
    expect(posts, hasLength(1));
    expect(posts[0].text, 'Found it');
  });

  test('an expired access token refreshes and the call retries',
      () async {
    await store.saveToken('bluesky', 'expired-jwt');
    await store.saveValue('bluesky_refresh_jwt', 'test-refresh-jwt');
    await store.saveValue('bluesky_handle', aliceHandle);
    await store.saveValue('bluesky_did', aliceDid);
    final List<Post> posts = await adapter.fetchTimeline();
    expect(posts, hasLength(2));
    expect(posts[0].authorName, 'Alice');
    // The refreshed tokens were persisted by the adapter.
    expect(await store.readToken('bluesky'), 'new-access-jwt');
    expect(
      await store.readValue('bluesky_refresh_jwt'),
      'new-refresh-jwt',
    );
    final int refreshCalls = server.sentRequests
        .where(
          (http.Request r) =>
              r.url.path == '/xrpc/com.atproto.server.refreshSession',
        )
        .length;
    expect(refreshCalls, 1);
  });

  test('a dead refresh token throws instead of looping', () async {
    await store.saveToken('bluesky', 'expired-jwt');
    await store.saveValue('bluesky_refresh_jwt', 'bad-refresh-jwt');
    await expectLater(
      adapter.fetchTimeline(),
      throwsA(isA<BlueskyApiException>()),
    );
    final int refreshCalls = server.sentRequests
        .where(
          (http.Request r) =>
              r.url.path == '/xrpc/com.atproto.server.refreshSession',
        )
        .length;
    expect(refreshCalls, 1);
    final int timelineCalls = server.sentRequests
        .where(
          (http.Request r) =>
              r.url.path == '/xrpc/app.bsky.feed.getTimeline',
        )
        .length;
    expect(timelineCalls, 1);
  });

  test('unreachable service throws a clear error', () async {
    await adapter.setService('offline.invalid');
    await expectLater(
      adapter.loginWithAppPassword(
        handle: aliceHandle,
        appPassword: 'app-password-1234',
      ),
      throwsA(
        isA<BlueskyApiException>().having(
          (BlueskyApiException e) => e.message,
          'message',
          contains('Could not reach offline.invalid'),
        ),
      ),
    );
  });

  test('actions without login throw', () async {
    await expectLater(
      adapter.postText('nope'),
      throwsA(isA<BlueskyNotLoggedInException>()),
    );
    await expectLater(
      adapter.likePost(alicePostUri, alicePostCid),
      throwsA(isA<BlueskyNotLoggedInException>()),
    );
    await expectLater(
      adapter.fetchNotifications(),
      throwsA(isA<BlueskyNotLoggedInException>()),
    );
    await expectLater(
      adapter.followAccount('did:plc:bob123'),
      throwsA(isA<BlueskyNotLoggedInException>()),
    );
  });

  test('logout clears the session but keeps the service', () async {
    await logIn();
    expect(await adapter.isLoggedIn, isTrue);
    await adapter.logout();
    expect(await adapter.isLoggedIn, isFalse);
    expect(await store.readToken('bluesky'), isNull);
    expect(await store.readValue('bluesky_refresh_jwt'), isNull);
    expect(await store.readValue('bluesky_handle'), isNull);
    expect(await adapter.service, 'bsky.social');
  });

  test('switching PDS forgets the login', () async {
    await logIn();
    expect(await adapter.isLoggedIn, isTrue);
    await adapter.setService('other-pds.example');
    expect(await adapter.isLoggedIn, isFalse);
    expect(await adapter.service, 'other-pds.example');
  });
}
