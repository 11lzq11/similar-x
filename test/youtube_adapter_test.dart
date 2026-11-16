// YouTube adapter tests, driven by a scripted fake HTTP transport.
//
// No real Google API, network or account is involved: [MockClient]
// answers Data API v3 and OAuth calls with canned JSON. The OAuth
// flow is exercised end to end (authorize URL -> loopback code ->
// token exchange -> tokens stored), including the access-token
// refresh on a 401. The loopback listener test uses real TCP on
// 127.0.0.1 only.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:similar_x/adapters/youtube/youtube_client.dart';
import 'package:similar_x/adapters/youtube/youtube_models.dart';
import 'package:similar_x/adapters/youtube_adapter.dart';
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

const String testApiKey = 'AIza-test-key';
const String testClientId =
    '123456789012-abcdef.apps.googleusercontent.com';
const String testAccessToken = 'ya29.test-access';
const String testRefreshToken = '1//test-refresh';

Map<String, Object?> thumbnailsJson(String id) => <String, Object?>{
      'medium': <String, Object?>{
        'url': 'https://i.ytimg.com/vi/$id/mqdefault.jpg',
      },
      'high': <String, Object?>{
        'url': 'https://i.ytimg.com/vi/$id/hqdefault.jpg',
      },
    };

Map<String, Object?> videoJson({
  String id = 'vid1',
  String title = 'Test Video One',
  String channelId = 'ch1',
  String channelTitle = 'Channel One',
  String publishedAt = '2026-11-16T10:00:00Z',
  String duration = 'PT15M33S',
  String views = '12345',
  String likes = '678',
  String comments = '90',
}) =>
    <String, Object?>{
      'kind': 'youtube#video',
      'id': id,
      'snippet': <String, Object?>{
        'title': title,
        'channelId': channelId,
        'channelTitle': channelTitle,
        'description': 'A test video.',
        'publishedAt': publishedAt,
        'thumbnails': thumbnailsJson(id),
      },
      'contentDetails': <String, Object?>{'duration': duration},
      'statistics': <String, Object?>{
        'viewCount': views,
        'likeCount': likes,
        'commentCount': comments,
      },
    };

Map<String, Object?> searchVideoJson({
  String videoId = 'vid1',
  String title = 'Test Video One',
  String channelId = 'ch1',
  String channelTitle = 'Channel One',
  String publishedAt = '2026-11-16T10:00:00Z',
}) =>
    <String, Object?>{
      'kind': 'youtube#searchResult',
      'id': <String, Object?>{
        'kind': 'youtube#video',
        'videoId': videoId,
      },
      'snippet': <String, Object?>{
        'title': title,
        'channelId': channelId,
        'channelTitle': channelTitle,
        'description': 'A test video.',
        'publishedAt': publishedAt,
        'thumbnails': thumbnailsJson(videoId),
      },
    };

Map<String, Object?> channelJson({
  String id = 'ch1',
  String title = 'Channel One',
  String uploads = 'UU111',
  String subscribers = '1000',
  String videos = '42',
  String views = '99999',
}) =>
    <String, Object?>{
      'kind': 'youtube#channel',
      'id': id,
      'snippet': <String, Object?>{
        'title': title,
        'description': 'A test channel.',
        'thumbnails': thumbnailsJson(id),
      },
      'contentDetails': <String, Object?>{
        'relatedPlaylists': <String, Object?>{'uploads': uploads},
      },
      'statistics': <String, Object?>{
        'subscriberCount': subscribers,
        'videoCount': videos,
        'viewCount': views,
      },
    };

Map<String, Object?> playlistItemJson({
  String videoId = 'vid1',
  String title = 'Test Video One',
  String channelId = 'ch1',
  String channelTitle = 'Channel One',
  String publishedAt = '2026-11-16T10:00:00Z',
}) =>
    <String, Object?>{
      'kind': 'youtube#playlistItem',
      'snippet': <String, Object?>{
        'title': title,
        'channelId': channelId,
        'channelTitle': channelTitle,
        'publishedAt': publishedAt,
        'thumbnails': thumbnailsJson(videoId),
        'resourceId': <String, Object?>{
          'kind': 'youtube#video',
          'videoId': videoId,
        },
      },
    };

Map<String, Object?> subscriptionJson({
  String id = 'sub1',
  String channelId = 'ch1',
  String channelTitle = 'Channel One',
  String publishedAt = '2026-11-15T09:00:00Z',
}) =>
    <String, Object?>{
      'kind': 'youtube#subscription',
      'id': id,
      'snippet': <String, Object?>{
        'title': channelTitle,
        'description': 'A subscribed channel.',
        'publishedAt': publishedAt,
        'thumbnails': thumbnailsJson(channelId),
        'resourceId': <String, Object?>{
          'kind': 'youtube#channel',
          'channelId': channelId,
        },
      },
    };

Map<String, Object?> commentJson({
  String id = 'ct1',
  String videoId = 'vid1',
  String author = 'Bob',
  String text = 'Great video!',
  int likes = 5,
  String publishedAt = '2026-11-16T11:00:00Z',
}) =>
    <String, Object?>{
      'kind': 'youtube#commentThread',
      'id': id,
      'snippet': <String, Object?>{
        'videoId': videoId,
        'totalReplyCount': 2,
        'topLevelComment': <String, Object?>{
          'kind': 'youtube#comment',
          'snippet': <String, Object?>{
            'authorDisplayName': author,
            'authorChannelId': <String, Object?>{
              'value': 'chBob',
            },
            'authorProfileImageUrl': 'https://example.com/bob.jpg',
            'textDisplay': text,
            'likeCount': likes,
            'publishedAt': publishedAt,
          },
        },
      },
    };

Map<String, Object?> tokenJson({
  String access = 'ya29.new-access',
  String? refresh = '1//new-refresh',
}) {
  final Map<String, Object?> json = <String, Object?>{
    'access_token': access,
    'expires_in': 3599,
    'token_type': 'Bearer',
  };
  if (refresh != null) json['refresh_token'] = refresh;
  return json;
}

http.Response jsonResponse(Object? body, [int status = 200]) =>
    http.Response(json.encode(body), status,
        headers: <String, String>{'content-type': 'application/json'});

/// A scripted fake transport. Records every request so tests can
/// assert on URLs, headers and bodies. [failSearchWithQuota]
/// makes search.list answer 403 quotaExceeded; [failFirstAuth]
/// makes the first OAuth-authenticated call answer 401 so the
/// auto-refresh path is exercised.
MockClient scriptedTransport({
  List<http.BaseRequest>? requests,
  bool failSearchWithQuota = false,
  bool failFirstAuth = false,
}) {
  final List<http.BaseRequest> seen =
      requests ?? <http.BaseRequest>[];
  int authCalls = 0;
  return MockClient((http.Request request) async {
    seen.add(request);
    final Uri url = request.url;
    final String path = url.path;
    if (url.host == 'oauth2.googleapis.com') {
      final Map<String, String> body =
          Uri.splitQueryString(request.body);
      if (body['grant_type'] == 'refresh_token') {
        return jsonResponse(tokenJson(refresh: null));
      }
      return jsonResponse(tokenJson());
    }
    final bool authed =
        (request.headers['Authorization'] ?? '').isNotEmpty;
    if (failFirstAuth && authed) {
      authCalls += 1;
      if (authCalls == 1) {
        return http.Response('{"error":{"message":"Unauthorized"}}', 401);
      }
    }
    if (path == '/youtube/v3/search') {
      if (failSearchWithQuota) {
        return jsonResponse(<String, Object?>{
          'error': <String, Object?>{
            'code': 403,
            'message': 'The request cannot be completed because you '
                'have exceeded your quota.',
            'errors': <Object?>[
              <String, Object?>{
                'reason': 'quotaExceeded',
                'message': 'Quota exceeded.',
              },
            ],
          },
        }, 403);
      }
      if (url.queryParameters['type'] == 'channel') {
        return jsonResponse(<String, Object?>{
          'items': <Object?>[
            <String, Object?>{
              'kind': 'youtube#searchResult',
              'id': <String, Object?>{
                'kind': 'youtube#channel',
                'channelId': 'ch1',
              },
              'snippet': <String, Object?>{
                'title': 'Channel One',
                'channelId': 'ch1',
                'description': 'A test channel.',
                'publishedAt': '2026-11-16T10:00:00Z',
                'thumbnails': thumbnailsJson('ch1'),
              },
            },
          ],
        });
      }
      return jsonResponse(<String, Object?>{
        'items': <Object?>[
          searchVideoJson(),
          searchVideoJson(
            videoId: 'vid2',
            title: 'Test Video Two',
            channelId: 'ch2',
            channelTitle: 'Channel Two',
            publishedAt: '2026-11-16T09:00:00Z',
          ),
        ],
      });
    }
    if (path == '/youtube/v3/videos/rate') {
      return http.Response('', 204);
    }
    if (path == '/youtube/v3/videos') {
      if (url.queryParameters['chart'] == 'mostPopular') {
        return jsonResponse(<String, Object?>{
          'items': <Object?>[
            videoJson(),
            videoJson(
              id: 'vid2',
              title: 'Test Video Two',
              channelId: 'ch2',
              channelTitle: 'Channel Two',
              publishedAt: '2026-11-16T09:00:00Z',
            ),
          ],
        });
      }
      final List<String> ids =
          (url.queryParameters['id'] ?? '').split(',');
      final Map<String, Map<String, Object?>> byId =
          <String, Map<String, Object?>>{
        'vid1': videoJson(),
        'vid2': videoJson(
          id: 'vid2',
          title: 'Test Video Two',
          channelId: 'ch2',
          channelTitle: 'Channel Two',
          publishedAt: '2026-11-16T09:00:00Z',
        ),
        'vidA': videoJson(
          id: 'vidA',
          title: 'Upload A',
          channelId: 'ch1',
          channelTitle: 'Channel One',
          publishedAt: '2026-11-16T12:00:00Z',
        ),
        'vidB': videoJson(
          id: 'vidB',
          title: 'Upload B',
          channelId: 'ch2',
          channelTitle: 'Channel Two',
          publishedAt: '2026-11-16T11:00:00Z',
        ),
      };
      return jsonResponse(<String, Object?>{
        'items': <Object?>[
          for (final String id in ids)
            if (byId.containsKey(id)) byId[id]!,
        ],
      });
    }
    if (path == '/youtube/v3/channels') {
      final List<String> ids =
          (url.queryParameters['id'] ?? '').split(',');
      return jsonResponse(<String, Object?>{
        'items': <Object?>[
          for (final String id in ids)
            if (id == 'ch1')
              channelJson()
            else if (id == 'ch2')
              channelJson(
                id: 'ch2',
                title: 'Channel Two',
                uploads: 'UU222',
              ),
        ],
      });
    }
    if (path == '/youtube/v3/playlistItems') {
      final String playlistId =
          url.queryParameters['playlistId'] ?? '';
      if (playlistId == 'UU111') {
        return jsonResponse(<String, Object?>{
          'items': <Object?>[
            playlistItemJson(
              videoId: 'vidA',
              title: 'Upload A',
              publishedAt: '2026-11-16T12:00:00Z',
            ),
          ],
        });
      }
      return jsonResponse(<String, Object?>{
        'items': <Object?>[
          playlistItemJson(
            videoId: 'vidB',
            title: 'Upload B',
            channelId: 'ch2',
            channelTitle: 'Channel Two',
            publishedAt: '2026-11-16T11:00:00Z',
          ),
        ],
      });
    }
    if (path == '/youtube/v3/subscriptions') {
      if (request.method == 'POST') {
        final Map<String, dynamic> body =
            json.decode(request.body) as Map<String, dynamic>;
        final Map<String, dynamic> snippet =
            body['snippet'] as Map<String, dynamic>;
        final Map<String, dynamic> resourceId =
            snippet['resourceId'] as Map<String, dynamic>;
        return jsonResponse(subscriptionJson(
          channelId: resourceId['channelId'] as String,
          channelTitle: 'Channel One',
        ));
      }
      if (request.method == 'DELETE') {
        return http.Response('', 204);
      }
      return jsonResponse(<String, Object?>{
        'items': <Object?>[
          subscriptionJson(),
          subscriptionJson(
            id: 'sub2',
            channelId: 'ch2',
            channelTitle: 'Channel Two',
          ),
        ],
      });
    }
    if (path == '/youtube/v3/commentThreads') {
      if (request.method == 'POST') {
        return jsonResponse(commentJson(
          text: 'Posted from Similar-X!',
        ));
      }
      return jsonResponse(<String, Object?>{
        'items': <Object?>[
          commentJson(),
          commentJson(
            id: 'ct2',
            author: 'Carol',
            text: 'Second comment.',
            likes: 2,
          ),
        ],
      });
    }
    return http.Response('{"error":{"message":"not found"}}', 404);
  });
}

YouTubeAdapter adapterWith({
  MockClient? transport,
  FakeAccountStore? store,
  bool withApiKey = true,
  bool loggedIn = false,
}) {
  final FakeAccountStore accountStore = store ?? FakeAccountStore();
  if (withApiKey) accountStore.values['youtube_api_key'] = testApiKey;
  accountStore.values['youtube_oauth_client_id'] = testClientId;
  if (loggedIn) {
    accountStore.values['similar_x_token_youtube'] = testAccessToken;
    accountStore.values['youtube_refresh_token'] = testRefreshToken;
  }
  final YouTubeClient client = YouTubeClient(
    httpClient: transport ?? scriptedTransport(),
  );
  return YouTubeAdapter(client: client, accountStore: accountStore);
}

void main() {
  group('quota constants', () {
    test('search is the expensive call', () {
      expect(youtubeQuotaSearchList, 100);
      expect(youtubeDailyQuotaUnits, 10000);
      // ~100 searches exhaust a default day of quota.
      expect(youtubeDailyQuotaUnits ~/ youtubeQuotaSearchList, 100);
    });

    test('metadata reads cost 1 unit, writes cost 50', () {
      expect(youtubeQuotaVideosList, 1);
      expect(youtubeQuotaChannelsList, 1);
      expect(youtubeQuotaPlaylistItemsList, 1);
      expect(youtubeQuotaSubscriptionsList, 1);
      expect(youtubeQuotaCommentThreadsList, 1);
      expect(youtubeQuotaVideosRate, 50);
      expect(youtubeQuotaSubscriptionsInsert, 50);
      expect(youtubeQuotaSubscriptionsDelete, 50);
      expect(youtubeQuotaCommentThreadsInsert, 50);
    });
  });

  group('models', () {
    test('ISO 8601 durations parse', () {
      expect(parseIso8601Duration('PT15M33S'),
          const Duration(minutes: 15, seconds: 33));
      expect(parseIso8601Duration('PT1H2M3S'),
          const Duration(hours: 1, minutes: 2, seconds: 3));
      expect(parseIso8601Duration('P1DT2H'),
          const Duration(days: 1, hours: 2));
      expect(parseIso8601Duration(null), Duration.zero);
      expect(parseIso8601Duration('garbage'), Duration.zero);
    });

    test('best thumbnail prefers maxres then falls back', () {
      expect(
        bestThumbnail(<String, dynamic>{
          'maxres': <String, dynamic>{'url': 'https://x/max.jpg'},
          'default': <String, dynamic>{'url': 'https://x/def.jpg'},
        }),
        'https://x/max.jpg',
      );
      expect(
        bestThumbnail(<String, dynamic>{
          'default': <String, dynamic>{'url': 'https://x/def.jpg'},
        }),
        'https://x/def.jpg',
      );
      expect(bestThumbnail(null), isNull);
    });

    test('video watch URL', () {
      expect(youtubeWatchUrl('abc123'),
          'https://www.youtube.com/watch?v=abc123');
    });
  });

  group('guest mode (API key only)', () {
    test('search needs an API key', () async {
      final YouTubeAdapter adapter = adapterWith(withApiKey: false);
      expect(
        adapter.searchVideos('flutter'),
        throwsA(isA<YouTubeApiException>().having(
          (YouTubeApiException e) => e.message,
          'message',
          contains('API key'),
        )),
      );
    });

    test('search parses videos and enriches with details', () async {
      final List<http.BaseRequest> seen = <http.BaseRequest>[];
      final YouTubeAdapter adapter =
          adapterWith(transport: scriptedTransport(requests: seen));
      final List<YouTubeVideo> videos =
          await adapter.searchVideos('flutter', limit: 10);
      expect(videos.length, 2);
      expect(videos[0].id, 'vid1');
      expect(videos[0].title, 'Test Video One');
      expect(videos[0].watchUrl,
          'https://www.youtube.com/watch?v=vid1');
      // Enriched by the follow-up videos.list call.
      expect(videos[0].duration, const Duration(minutes: 15, seconds: 33));
      expect(videos[0].viewCount, 12345);
      expect(videos[1].id, 'vid2');
      // The search request itself carried the query and the key.
      final Uri searchUrl =
          seen.firstWhere((http.BaseRequest r) =>
              r.url.path == '/youtube/v3/search').url;
      expect(searchUrl.queryParameters['q'], 'flutter');
      expect(searchUrl.queryParameters['type'], 'video');
      expect(searchUrl.queryParameters['key'], testApiKey);
    });

    test('search channels parses channel results', () async {
      final YouTubeAdapter adapter = adapterWith();
      final List<YouTubeChannel> channels =
          await adapter.searchChannels('channel one');
      expect(channels.length, 1);
      expect(channels[0].id, 'ch1');
      expect(channels[0].title, 'Channel One');
    });

    test('video details carry duration and statistics', () async {
      final YouTubeAdapter adapter = adapterWith();
      final YouTubeVideo? video =
          await adapter.fetchVideoDetails('vid1');
      expect(video, isNotNull);
      expect(video!.duration, const Duration(minutes: 15, seconds: 33));
      expect(video.viewCount, 12345);
      expect(video.likeCount, 678);
      expect(video.commentCount, 90);
    });

    test('channel details carry uploads playlist and counts', () async {
      final YouTubeAdapter adapter = adapterWith();
      final YouTubeChannel? channel =
          await adapter.fetchChannel('ch1');
      expect(channel, isNotNull);
      expect(channel!.uploadsPlaylistId, 'UU111');
      expect(channel.subscriberCount, 1000);
      expect(channel.videoCount, 42);
    });

    test('guest timeline is the most popular chart', () async {
      final YouTubeAdapter adapter = adapterWith();
      final List<Post> timeline = await adapter.fetchTimeline(limit: 2);
      expect(timeline.length, 2);
      expect(timeline[0].platformId, 'youtube');
      expect(timeline[0].text, 'Test Video One');
      expect(timeline[0].authorName, 'Channel One');
      expect(timeline[0].likeCount, 678);
    });

    test('channel uploads resolve the uploads playlist', () async {
      final YouTubeAdapter adapter = adapterWith();
      final List<YouTubeVideo> uploads =
          await adapter.fetchChannelUploads('ch1', limit: 5);
      expect(uploads.length, 1);
      expect(uploads[0].id, 'vidA');
      expect(uploads[0].title, 'Upload A');
    });

    test('comments list parses authors and likes', () async {
      final YouTubeAdapter adapter = adapterWith();
      final List<YouTubeComment> comments =
          await adapter.fetchComments('vid1');
      expect(comments.length, 2);
      expect(comments[0].authorName, 'Bob');
      expect(comments[0].text, 'Great video!');
      expect(comments[0].likeCount, 5);
      expect(comments[1].authorName, 'Carol');
    });

    test('quota error names the quota', () async {
      final YouTubeAdapter adapter = adapterWith(
        transport: scriptedTransport(failSearchWithQuota: true),
      );
      expect(
        adapter.searchVideos('flutter'),
        throwsA(isA<YouTubeApiException>().having(
          (YouTubeApiException e) => e.message,
          'message',
          contains('quota'),
        )),
      );
    });
  });

  group('logged-in mode (OAuth)', () {
    test('isLoggedIn follows the stored refresh token', () async {
      final FakeAccountStore store = FakeAccountStore();
      store.values['youtube_api_key'] = testApiKey;
      final YouTubeAdapter loggedOut = YouTubeAdapter(
        client: YouTubeClient(httpClient: scriptedTransport()),
        accountStore: store,
      );
      expect(await loggedOut.isLoggedIn, isFalse);
      store.values['youtube_refresh_token'] = testRefreshToken;
      expect(await loggedOut.isLoggedIn, isTrue);
    });

    test('subscriptions feed merges uploads newest first', () async {
      final List<http.BaseRequest> seen = <http.BaseRequest>[];
      final YouTubeAdapter adapter = adapterWith(
        transport: scriptedTransport(requests: seen),
        loggedIn: true,
      );
      final List<Post> timeline = await adapter.fetchTimeline(limit: 5);
      expect(timeline.length, 2);
      // Upload A (12:00) is newer than Upload B (11:00).
      expect(timeline[0].text, 'Upload A');
      expect(timeline[1].text, 'Upload B');
      // The subscriptions call used OAuth and mine=true.
      final http.BaseRequest subsCall = seen.firstWhere(
        (http.BaseRequest r) =>
            r.url.path == '/youtube/v3/subscriptions' &&
            r.method == 'GET',
      );
      expect(subsCall.url.queryParameters['mine'], 'true');
      expect(subsCall.headers['Authorization'],
          'Bearer $testAccessToken');
    });

    test('like and unlike call videos.rate with OAuth', () async {
      final List<http.BaseRequest> seen = <http.BaseRequest>[];
      final YouTubeAdapter adapter = adapterWith(
        transport: scriptedTransport(requests: seen),
        loggedIn: true,
      );
      await adapter.likeVideo('vid1');
      await adapter.unlikeVideo('vid1');
      final List<http.BaseRequest> rates = seen
          .where((http.BaseRequest r) =>
              r.url.path == '/youtube/v3/videos/rate')
          .toList();
      expect(rates.length, 2);
      expect(rates[0].url.queryParameters['rating'], 'like');
      expect(rates[1].url.queryParameters['rating'], 'none');
      expect(rates[0].url.queryParameters['id'], 'vid1');
      expect(rates[0].headers['Authorization'],
          'Bearer $testAccessToken');
    });

    test('subscribe posts the channel id; unsubscribe deletes', () async {
      final List<http.BaseRequest> seen = <http.BaseRequest>[];
      final YouTubeAdapter adapter = adapterWith(
        transport: scriptedTransport(requests: seen),
        loggedIn: true,
      );
      final YouTubeSubscription sub =
          await adapter.subscribeToChannel('ch1');
      expect(sub.channelId, 'ch1');
      await adapter.unsubscribeFromChannel('ch1');
      final http.BaseRequest deleteCall = seen.firstWhere(
        (http.BaseRequest r) =>
            r.url.path == '/youtube/v3/subscriptions' &&
            r.method == 'DELETE',
      );
      // The subscription id came from the subscriptions list.
      expect(deleteCall.url.queryParameters['id'], 'sub1');
    });

    test('post comment sends video id and text', () async {
      final List<http.BaseRequest> seen = <http.BaseRequest>[];
      final YouTubeAdapter adapter = adapterWith(
        transport: scriptedTransport(requests: seen),
        loggedIn: true,
      );
      final YouTubeComment comment = await adapter.postComment(
        'vid1',
        'Posted from Similar-X!',
      );
      expect(comment.text, 'Posted from Similar-X!');
      final http.Request postCall = seen.firstWhere(
        (http.BaseRequest r) =>
            r.url.path == '/youtube/v3/commentThreads' &&
            r.method == 'POST',
      ) as http.Request;
      final Map<String, dynamic> body =
          json.decode(postCall.body) as Map<String, dynamic>;
      final Map<String, dynamic> snippet =
          body['snippet'] as Map<String, dynamic>;
      expect(snippet['videoId'], 'vid1');
    });

    test('logged-in actions throw when logged out', () async {
      final YouTubeAdapter adapter = adapterWith(loggedIn: false);
      expect(adapter.likeVideo('vid1'),
          throwsA(isA<YouTubeNotLoggedInException>()));
      expect(adapter.subscribeToChannel('ch1'),
          throwsA(isA<YouTubeNotLoggedInException>()));
      expect(adapter.postComment('vid1', 'hi'),
          throwsA(isA<YouTubeNotLoggedInException>()));
    });

    test('401 refreshes the token once and retries', () async {
      final FakeAccountStore store = FakeAccountStore();
      final YouTubeAdapter adapter = adapterWith(
        transport: scriptedTransport(failFirstAuth: true),
        store: store,
        loggedIn: true,
      );
      final List<YouTubeSubscription> subs =
          await adapter.fetchMySubscriptions();
      expect(subs.length, 2);
      // The refreshed access token was persisted.
      expect(store.values['similar_x_token_youtube'],
          'ya29.new-access');
    });
  });

  group('OAuth flow', () {
    test('login() directs to the real login methods', () async {
      final YouTubeAdapter adapter = adapterWith();
      expect(adapter.login(),
          throwsA(isA<YouTubeApiException>()));
    });

    test('beginOAuthLogin needs a client ID', () async {
      final FakeAccountStore store = FakeAccountStore();
      store.values['youtube_api_key'] = testApiKey;
      final YouTubeAdapter adapter = YouTubeAdapter(
        client: YouTubeClient(httpClient: scriptedTransport()),
        accountStore: store,
      );
      expect(adapter.beginOAuthLogin(),
          throwsA(isA<YouTubeApiException>()));
    });

    test('authorize URL carries PKCE, scope and loopback redirect',
        () async {
      final YouTubeAdapter adapter = adapterWith();
      final Uri url = await adapter.beginOAuthLogin();
      expect(url.host, 'accounts.google.com');
      expect(url.queryParameters['response_type'], 'code');
      expect(url.queryParameters['client_id'], testClientId);
      expect(url.queryParameters['scope'], youtubeOAuthScope);
      expect(url.queryParameters['code_challenge_method'], 'S256');
      expect(
        url.queryParameters['code_challenge'],
        isNotEmpty,
      );
      expect(url.queryParameters['redirect_uri'],
          startsWith('http://127.0.0.1:'));
      await adapter.cancelOAuthLogin();
    });

    test('token exchange stores access and refresh tokens', () async {
      final FakeAccountStore store = FakeAccountStore();
      final YouTubeAdapter adapter = adapterWith(
        transport: scriptedTransport(),
        store: store,
      );
      await adapter.beginOAuthLogin();
      await adapter.completeOAuthLoginWithCode('4/0test-code');
      expect(store.values['similar_x_token_youtube'],
          'ya29.new-access');
      expect(store.values['youtube_refresh_token'], '1//new-refresh');
      expect(await adapter.isLoggedIn, isTrue);
    });

    test('completeOAuthLogin without begin throws', () async {
      final YouTubeAdapter adapter = adapterWith();
      expect(adapter.completeOAuthLogin(),
          throwsA(isA<YouTubeApiException>()));
      expect(adapter.completeOAuthLoginWithCode('code'),
          throwsA(isA<YouTubeApiException>()));
    });

    test('logout deletes tokens but keeps the API key', () async {
      final FakeAccountStore store = FakeAccountStore();
      final YouTubeAdapter adapter = adapterWith(
        store: store,
        loggedIn: true,
      );
      expect(await adapter.isLoggedIn, isTrue);
      await adapter.logout();
      expect(await adapter.isLoggedIn, isFalse);
      expect(store.values.containsKey('similar_x_token_youtube'),
          isFalse);
      expect(store.values.containsKey('youtube_refresh_token'),
          isFalse);
      expect(store.values['youtube_api_key'], testApiKey);
    });

    test('adapter metadata', () {
      final YouTubeAdapter adapter = adapterWith();
      expect(adapter.id, 'youtube');
      expect(adapter.displayName, 'YouTube');
      expect(adapter.status, PlatformStatus.limited);
      expect(adapter.capabilities, contains(AdapterCapability.timeline));
      expect(adapter.capabilities, contains(AdapterCapability.search));
      expect(adapter.capabilities, contains(AdapterCapability.like));
      expect(adapter.capabilities, contains(AdapterCapability.comment));
      expect(adapter.requiresLogin, isFalse);
    });
  });

  group('loopback listener', () {
    test('captures the code from the redirect', () async {
      final LoopbackAuthListener listener =
          await LoopbackAuthListener.start();
      final Uri redirect = Uri.parse(listener.redirectUri);
      expect(redirect.host, '127.0.0.1');
      final HttpClient httpClient = HttpClient();
      final HttpClientRequest request = await httpClient
          .getUrl(redirect.replace(queryParameters: <String, String>{
        'code': '4/0loopback-code',
      }));
      final HttpClientResponse response = await request.close();
      await response.drain<void>();
      httpClient.close();
      expect(await listener.code, '4/0loopback-code');
    });

    test('cancel fails the pending code', () async {
      final LoopbackAuthListener listener =
          await LoopbackAuthListener.start();
      final Future<String> codeFuture = listener.code;
      await listener.cancel();
      expect(codeFuture, throwsA(isA<YouTubeApiException>()));
    });
  });
}
