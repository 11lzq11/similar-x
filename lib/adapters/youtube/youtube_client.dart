/// YouTube Data API v3 client: plain HTTPS + JSON over
/// `package:http`.
///
/// Auth has two layers, and they are deliberately separate:
/// * an **API key** (user-provided, from Google Cloud Console)
///   covers all public reads — search, video/channel details,
///   playlists, public subscriptions, comments. No login needed.
/// * **OAuth 2.0** (Google account, PKCE, loopback redirect)
///   unlocks the account actions: my subscriptions, likes,
///   subscribing, posting comments. The access token is short
///   lived; the client refreshes it once on a 401 and retries.
///
/// Quota (Google's quota calculator, per call):
/// * search.list: 100 units — the bottleneck. Default project
///   quota is 10,000 units/day, so ~100 searches/day max.
/// * videos.list / channels.list / playlistItems.list /
///   subscriptions.list / commentThreads.list: 1 unit.
/// * videos.rate / subscriptions.insert / subscriptions.delete /
///   commentThreads.insert: 50 units.
///
/// The official API never serves video streams — playback needs
/// InnerTube (unofficial) or the official IFrame player in a
/// WebView, both follow-ups. This client only moves metadata.
///
/// How to get an API key / OAuth client (both are per-user, from
/// the user's own Google Cloud project — Similar-X ships no
/// shared key, so one user's quota can never eat another's):
/// 1. console.cloud.google.com > create a project > enable
///    "YouTube Data API v3".
/// 2. Credentials > Create > API key — paste it in Similar-X.
/// 3. Credentials > Create > OAuth client ID > Desktop app —
///    paste the client ID in Similar-X for login (likes,
///    subscriptions, comments).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'youtube_models.dart';

/// Thrown when a YouTube API call fails: missing API key, wrong
/// key, quota exhausted, network error, or a non-2xx response.
/// [statusCode] is the HTTP status when the server answered, null
/// when the request never reached it.
class YouTubeApiException implements Exception {
  const YouTubeApiException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() =>
      'YouTubeApiException: $message'
      '${statusCode == null ? '' : ' (HTTP $statusCode)'}';
}

/// The YouTube Data API v3 host.
const String youtubeApiHost = 'www.googleapis.com';

/// The Google OAuth authorization endpoint.
const String youtubeAuthHost = 'accounts.google.com';

/// The Google OAuth token endpoint.
const String youtubeTokenHost = 'oauth2.googleapis.com';

/// The OAuth scope Similar-X asks for: read + write on the user's
/// YouTube account (subscriptions, likes, comments). The smallest
/// scope that covers the adapter's logged-in capabilities.
const String youtubeOAuthScope =
    'https://www.googleapis.com/auth/youtube.force-ssl';

/// Default project quota: 10,000 units/day (midnight Pacific).
const int youtubeDailyQuotaUnits = 10000;

/// Quota cost per call, from Google's quota calculator.
const int youtubeQuotaSearchList = 100;
const int youtubeQuotaVideosList = 1;
const int youtubeQuotaChannelsList = 1;
const int youtubeQuotaPlaylistItemsList = 1;
const int youtubeQuotaSubscriptionsList = 1;
const int youtubeQuotaCommentThreadsList = 1;
const int youtubeQuotaVideosRate = 50;
const int youtubeQuotaSubscriptionsInsert = 50;
const int youtubeQuotaSubscriptionsDelete = 50;
const int youtubeQuotaCommentThreadsInsert = 50;

/// PKCE code verifier: 64 random bytes, base64url without padding
/// (86 chars, inside the 43–128 range the spec requires).
String generateCodeVerifier() {
  final Random random = Random.secure();
  final List<int> bytes =
      List<int>.generate(64, (_) => random.nextInt(256));
  return base64Url.encode(bytes).replaceAll('=', '');
}

/// PKCE S256 code challenge for [verifier]: base64url(SHA-256)
/// without padding.
String codeChallengeS256(String verifier) {
  final List<int> digest = sha256.convert(utf8.encode(verifier)).bytes;
  return base64Url.encode(digest).replaceAll('=', '');
}

/// A loopback listener for the OAuth redirect: binds 127.0.0.1 on
/// an ephemeral port, waits for Google to redirect the browser to
/// `http://127.0.0.1:<port>/?code=...`, captures the code, answers
/// with a small success page and shuts down. [cancel] closes the
/// server without a code (the user closed the browser).
class LoopbackAuthListener {
  LoopbackAuthListener._(this._server, this._completer);

  static Future<LoopbackAuthListener> start() async {
    final HttpServer server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final Completer<String> completer = Completer<String>();
    // A silent error handler: cancelling a login nobody is
    // awaiting must not surface as an unhandled async error.
    // Awaiting [code] elsewhere still receives the error.
    unawaited(completer.future.catchError((Object _) => ''));
    server.listen((HttpRequest request) async {
      final String? code =
          request.uri.queryParameters['code'];
      final String? error =
          request.uri.queryParameters['error'];
      request.response.headers.contentType = ContentType.html;
      if (code != null && code.isNotEmpty) {
        request.response.write(
          '<html><body><h1>Similar-X</h1>'
          '<p>Login complete — you can close this tab and '
          'return to Similar-X.</p></body></html>',
        );
        await request.response.close();
        await server.close(force: true);
        if (!completer.isCompleted) completer.complete(code);
      } else {
        request.response.write(
          '<html><body><h1>Similar-X</h1>'
          '<p>Login failed'
          '${error == null ? '' : ': $error'}. '
          'You can close this tab and try again in Similar-X.'
          '</p></body></html>',
        );
        await request.response.close();
        await server.close(force: true);
        if (!completer.isCompleted) {
          completer.completeError(
            YouTubeApiException(
              'Login failed: Google returned '
              '${error ?? 'an unknown error'}.',
            ),
          );
        }
      }
    });
    return LoopbackAuthListener._(server, completer);
  }

  final HttpServer _server;
  final Completer<String> _completer;

  /// The redirect URI Google must send the browser to.
  String get redirectUri => 'http://127.0.0.1:${_server.port}';

  /// Completes with the authorization code when Google redirects
  /// here, or with a [YouTubeApiException] on error/cancel.
  Future<String> get code => _completer.future;

  /// Closes the listener without a code (user gave up). The
  /// pending [code] future completes with an error.
  Future<void> cancel() async {
    await _server.close(force: true);
    if (!_completer.isCompleted) {
      _completer.completeError(
        const YouTubeApiException('Login cancelled.'),
      );
    }
  }
}

/// One YouTube account's API client.
///
/// The client holds no credential by itself: [apiKey] /
/// [accessToken] / [refreshToken] are set by the adapter after
/// the user enters them and cleared on logout. Calls without any
/// credential throw — the API key is the minimum for public reads.
class YouTubeClient {
  YouTubeClient({this.apiKey, http.Client? httpClient})
      : _http = httpClient ?? http.Client();

  /// The user's Data API v3 key. Required for public reads.
  String? apiKey;

  /// The OAuth access token. Set after login; cleared on logout.
  String? accessToken;

  /// The OAuth refresh token. Set after login; cleared on logout.
  String? refreshToken;

  /// The user's Desktop-app OAuth client ID. Needed to refresh
  /// the access token — the adapter stores it and sets it here.
  String? oauthClientId;

  /// Called after an access-token refresh so the adapter can
  /// persist the new tokens. Null in tests that do not care
  /// about persistence.
  Future<void> Function(YouTubeTokens tokens)? onTokensRefreshed;

  final http.Client _http;

  Uri _apiUri(String path, [Map<String, String>? query]) {
    final Map<String, String> params = <String, String>{...?query};
    final String? key = apiKey;
    if (key != null && key.isNotEmpty) params['key'] = key;
    return Uri.https(
      youtubeApiHost,
      '/youtube/v3/$path',
      params.isEmpty ? null : params,
    );
  }

  Map<String, String> get _authHeaders {
    final String? token = accessToken;
    if (token == null || token.isEmpty) return const <String, String>{};
    return <String, String>{'Authorization': 'Bearer $token'};
  }

  /// The URL the user opens in a browser to authorize Similar-X.
  /// Google redirects to [redirectUri] with `?code=...` after
  /// approval; the adapter captures it with a
  /// [LoopbackAuthListener].
  Uri buildAuthorizeUrl({
    required String clientId,
    required String codeChallenge,
    required String redirectUri,
  }) =>
      Uri.https(youtubeAuthHost, '/o/oauth2/v2/auth', <String, String>{
        'response_type': 'code',
        'client_id': clientId,
        'redirect_uri': redirectUri,
        'scope': youtubeOAuthScope,
        'code_challenge': codeChallenge,
        'code_challenge_method': 'S256',
        'access_type': 'offline',
        'prompt': 'consent',
      });

  /// Exchanges the authorization code for access + refresh
  /// tokens. [clientId] is the user's Desktop-app OAuth client
  /// ID; no client secret is needed for installed apps with PKCE.
  Future<YouTubeTokens> exchangeCode({
    required String code,
    required String clientId,
    required String codeVerifier,
    required String redirectUri,
  }) async {
    final http.Response response = await _http.post(
      Uri.https(youtubeTokenHost, '/token'),
      body: <String, String>{
        'grant_type': 'authorization_code',
        'code': code,
        'client_id': clientId,
        'redirect_uri': redirectUri,
        'code_verifier': codeVerifier,
      },
    );
    final YouTubeTokens tokens = YouTubeTokens.fromJson(
      _decode(response) as Map<String, dynamic>,
    );
    if (!tokens.isValid) {
      throw const YouTubeApiException(
        'Token exchange failed: no access token returned.',
      );
    }
    _applyTokens(tokens);
    return tokens;
  }

  /// Refreshes the access token with the stored refresh token
  /// and applies the new tokens. Throws when there is no refresh
  /// token or Google rejects it — the user has to log in again.
  Future<YouTubeTokens> refreshAccessToken({
    required String clientId,
  }) async {
    final String? refresh = refreshToken;
    if (refresh == null || refresh.isEmpty) {
      throw const YouTubeApiException(
        'Session expired: log in again.',
      );
    }
    final http.Response response = await _http.post(
      Uri.https(youtubeTokenHost, '/token'),
      body: <String, String>{
        'grant_type': 'refresh_token',
        'refresh_token': refresh,
        'client_id': clientId,
      },
    );
    final YouTubeTokens tokens = YouTubeTokens.fromJson(
      _decode(response) as Map<String, dynamic>,
    );
    if (!tokens.isValid) {
      throw const YouTubeApiException(
        'Session refresh failed: log in again.',
      );
    }
    // Google does not always return a fresh refresh token; keep
    // the old one when the response has none.
    _applyTokens(
      YouTubeTokens(
        accessToken: tokens.accessToken,
        refreshToken: tokens.refreshToken ?? refresh,
        expiresInSeconds: tokens.expiresInSeconds,
      ),
    );
    await onTokensRefreshed?.call(
      YouTubeTokens(
        accessToken: tokens.accessToken,
        refreshToken: tokens.refreshToken ?? refresh,
        expiresInSeconds: tokens.expiresInSeconds,
      ),
    );
    return tokens;
  }

  void _applyTokens(YouTubeTokens tokens) {
    accessToken = tokens.accessToken;
    if (tokens.refreshToken != null &&
        tokens.refreshToken!.isNotEmpty) {
      refreshToken = tokens.refreshToken;
    }
  }

  /// Searches videos by keyword. Costs
  /// [youtubeQuotaSearchList] units per call — the scarce
  /// resource, so the adapter should not auto-refresh search.
  /// Results are enriched with one `videos.list` call (1 unit)
  /// so duration and view counts are filled in.
  Future<List<YouTubeVideo>> searchVideos(
    String query, {
    int limit = 10,
  }) async {
    _requireApiKey();
    final http.Response response = await _get(
      _apiUri('search', <String, String>{
        'part': 'snippet',
        'q': query,
        'type': 'video',
        'maxResults': limit.toString(),
      }),
    );
    final List<Object?> items = _decodeItems(response);
    final List<YouTubeVideo> videos = items
        .whereType<Map<String, dynamic>>()
        .map(YouTubeVideo.fromSearchJson)
        .where((YouTubeVideo v) => v.isValid)
        .toList();
    return enrichVideos(videos);
  }

  /// Searches channels by name. Costs
  /// [youtubeQuotaSearchList] units per call.
  Future<List<YouTubeChannel>> searchChannels(
    String query, {
    int limit = 10,
  }) async {
    _requireApiKey();
    final http.Response response = await _get(
      _apiUri('search', <String, String>{
        'part': 'snippet',
        'q': query,
        'type': 'channel',
        'maxResults': limit.toString(),
      }),
    );
    final List<Object?> items = _decodeItems(response);
    return items
        .whereType<Map<String, dynamic>>()
        .map(YouTubeChannel.fromSearchJson)
        .where((YouTubeChannel c) => c.isValid)
        .toList();
  }

  /// Full details (snippet, contentDetails, statistics) for up
  /// to 50 video ids in one call. Costs
  /// [youtubeQuotaVideosList] unit.
  Future<List<YouTubeVideo>> listVideos(
    List<String> videoIds, {
    List<String> parts = const <String>[
      'snippet',
      'contentDetails',
      'statistics',
    ],
  }) async {
    _requireApiKey();
    if (videoIds.isEmpty) return <YouTubeVideo>[];
    final http.Response response = await _get(
      _apiUri('videos', <String, String>{
        'part': parts.join(','),
        'id': videoIds.join(','),
      }),
    );
    final List<Object?> items = _decodeItems(response);
    return items
        .whereType<Map<String, dynamic>>()
        .map(YouTubeVideo.fromVideoJson)
        .where((YouTubeVideo v) => v.isValid)
        .toList();
  }

  /// Details for one video, or null when it does not exist.
  Future<YouTubeVideo?> getVideo(String videoId) async {
    final List<YouTubeVideo> videos = await listVideos(<String>[videoId]);
    return videos.isEmpty ? null : videos.first;
  }

  /// The most popular videos (the guest timeline). Costs
  /// [youtubeQuotaVideosList] unit.
  Future<List<YouTubeVideo>> listMostPopular({
    int limit = 20,
    String regionCode = 'US',
  }) async {
    _requireApiKey();
    final http.Response response = await _get(
      _apiUri('videos', <String, String>{
        'part': 'snippet,contentDetails,statistics',
        'chart': 'mostPopular',
        'regionCode': regionCode,
        'maxResults': limit.toString(),
      }),
    );
    final List<Object?> items = _decodeItems(response);
    return items
        .whereType<Map<String, dynamic>>()
        .map(YouTubeVideo.fromVideoJson)
        .where((YouTubeVideo v) => v.isValid)
        .toList();
  }

  /// Details for one or more channels. Costs
  /// [youtubeQuotaChannelsList] unit.
  Future<List<YouTubeChannel>> listChannels(
    List<String> channelIds,
  ) async {
    _requireApiKey();
    if (channelIds.isEmpty) return <YouTubeChannel>[];
    final http.Response response = await _get(
      _apiUri('channels', <String, String>{
        'part': 'snippet,contentDetails,statistics',
        'id': channelIds.join(','),
      }),
    );
    final List<Object?> items = _decodeItems(response);
    return items
        .whereType<Map<String, dynamic>>()
        .map(YouTubeChannel.fromChannelJson)
        .where((YouTubeChannel c) => c.isValid)
        .toList();
  }

  /// Details for one channel, or null when it does not exist.
  Future<YouTubeChannel?> getChannel(String channelId) async {
    final List<YouTubeChannel> channels =
        await listChannels(<String>[channelId]);
    return channels.isEmpty ? null : channels.first;
  }

  /// Items of a playlist (e.g. a channel's uploads playlist).
  /// Costs [youtubeQuotaPlaylistItemsList] unit.
  Future<List<YouTubeVideo>> listPlaylistItems(
    String playlistId, {
    int limit = 20,
  }) async {
    _requireApiKey();
    final http.Response response = await _get(
      _apiUri('playlistItems', <String, String>{
        'part': 'snippet,contentDetails',
        'playlistId': playlistId,
        'maxResults': limit.toString(),
      }),
    );
    final List<Object?> items = _decodeItems(response);
    return items
        .whereType<Map<String, dynamic>>()
        .map(YouTubeVideo.fromPlaylistItemJson)
        .where((YouTubeVideo v) => v.isValid)
        .toList();
  }

  /// The user's subscriptions (OAuth) or a channel's public
  /// subscriptions ([channelId]). Costs
  /// [youtubeQuotaSubscriptionsList] unit.
  Future<List<YouTubeSubscription>> listSubscriptions({
    bool mine = false,
    String? channelId,
    int limit = 50,
  }) async {
    if (mine) {
      final http.Response response = await _getAuthenticated(
        _apiUri('subscriptions', <String, String>{
          'part': 'snippet',
          'mine': 'true',
          'maxResults': limit.toString(),
        }),
      );
      return _decodeSubscriptions(response);
    }
    _requireApiKey();
    if (channelId == null || channelId.isEmpty) {
      throw const YouTubeApiException(
        'listSubscriptions needs mine=true (login) or a channelId.',
      );
    }
    final http.Response response = await _get(
      _apiUri('subscriptions', <String, String>{
        'part': 'snippet',
        'channelId': channelId,
        'maxResults': limit.toString(),
      }),
    );
    return _decodeSubscriptions(response);
  }

  List<YouTubeSubscription> _decodeSubscriptions(
    http.Response response,
  ) {
    final List<Object?> items = _decodeItems(response);
    return items
        .whereType<Map<String, dynamic>>()
        .map(YouTubeSubscription.fromJson)
        .where((YouTubeSubscription s) => s.isValid)
        .toList();
  }

  /// Subscribes to a channel. OAuth only. Costs
  /// [youtubeQuotaSubscriptionsInsert] units.
  Future<YouTubeSubscription> subscribe(String channelId) async {
    final http.Response response = await _postAuthenticated(
      _apiUri('subscriptions', <String, String>{'part': 'snippet'}),
      jsonBody: <String, Object?>{
        'snippet': <String, Object?>{
          'resourceId': <String, Object?>{
            'kind': 'youtube#channel',
            'channelId': channelId,
          },
        },
      },
    );
    return YouTubeSubscription.fromJson(
      _decode(response) as Map<String, dynamic>,
    );
  }

  /// Unsubscribes, given the subscription id from
  /// [listSubscriptions]. OAuth only. Costs
  /// [youtubeQuotaSubscriptionsDelete] units.
  Future<void> unsubscribe(String subscriptionId) async {
    await _postAuthenticated(
      _apiUri('subscriptions', <String, String>{'id': subscriptionId}),
      method: 'DELETE',
    );
  }

  /// Likes a video (`like`), dislikes it (`dislike`) or clears
  /// the rating (`none`). OAuth only. Costs
  /// [youtubeQuotaVideosRate] units.
  Future<void> rateVideo(
    String videoId, {
    String rating = 'like',
  }) async {
    const Set<String> allowed = <String>{'like', 'dislike', 'none'};
    if (!allowed.contains(rating)) {
      throw YouTubeApiException('Invalid rating: "$rating".');
    }
    await _postAuthenticated(
      _apiUri('videos/rate', <String, String>{
        'id': videoId,
        'rating': rating,
      }),
    );
  }

  /// Top-level comments on a video, newest first. Works with
  /// just the API key. Costs
  /// [youtubeQuotaCommentThreadsList] unit.
  Future<List<YouTubeComment>> listCommentThreads(
    String videoId, {
    int limit = 20,
  }) async {
    _requireApiKey();
    final http.Response response = await _get(
      _apiUri('commentThreads', <String, String>{
        'part': 'snippet',
        'videoId': videoId,
        'maxResults': limit.toString(),
        'order': 'time',
      }),
    );
    final List<Object?> items = _decodeItems(response);
    return items
        .whereType<Map<String, dynamic>>()
        .map(YouTubeComment.fromJson)
        .where((YouTubeComment c) => c.isValid)
        .toList();
  }

  /// Posts a top-level comment on a video. OAuth only. Costs
  /// [youtubeQuotaCommentThreadsInsert] units.
  Future<YouTubeComment> postComment(
    String videoId,
    String text,
  ) async {
    final http.Response response = await _postAuthenticated(
      _apiUri('commentThreads', <String, String>{'part': 'snippet'}),
      jsonBody: <String, Object?>{
        'snippet': <String, Object?>{
          'videoId': videoId,
          'topLevelComment': <String, Object?>{
            'snippet': <String, Object?>{'textOriginal': text},
          },
        },
      },
    );
    return YouTubeComment.fromJson(
      _decode(response) as Map<String, dynamic>,
    );
  }

  /// Enriches snippet-only videos (search / playlist results)
  /// with duration and statistics in a single `videos.list`
  /// call (1 unit for up to 50 ids). Videos with no details
  /// keep their snippet data.
  Future<List<YouTubeVideo>> enrichVideos(
    List<YouTubeVideo> videos,
  ) async {
    if (videos.isEmpty) return videos;
    final List<YouTubeVideo> details = await listVideos(
      videos.map((YouTubeVideo v) => v.id).toList(),
    );
    if (details.isEmpty) return videos;
    final Map<String, YouTubeVideo> byId = <String, YouTubeVideo>{
      for (final YouTubeVideo v in details) v.id: v,
    };
    return videos.map((YouTubeVideo v) => byId[v.id] ?? v).toList();
  }

  void _requireApiKey() {
    final String? key = apiKey;
    if (key == null || key.isEmpty) {
      throw const YouTubeApiException(
        'No YouTube API key set. Create one at Google Cloud '
        'Console (enable YouTube Data API v3, create an API key) '
        'and save it in Similar-X first.',
      );
    }
  }

  void _requireAccessToken() {
    final String? token = accessToken;
    if (token == null || token.isEmpty) {
      throw const YouTubeApiException(
        'Log in to YouTube first (Google OAuth).',
      );
    }
  }

  Future<http.Response> _get(Uri uri) async {
    http.Response response;
    try {
      response = await _http.get(uri);
    } catch (e) {
      throw YouTubeApiException('Network error: $e');
    }
    return _check(response);
  }

  /// An OAuth-authenticated GET: on a 401 the access token is
  /// refreshed once and the request retried.
  Future<http.Response> _getAuthenticated(Uri uri) async {
    _requireAccessToken();
    http.Response response = await _getRaw(uri, _authHeaders);
    if (response.statusCode == 401) {
      await _refreshOnce();
      response = await _getRaw(uri, _authHeaders);
    }
    return _check(response);
  }

  Future<http.Response> _getRaw(
    Uri uri,
    Map<String, String> headers,
  ) async {
    try {
      return await _http.get(uri, headers: headers);
    } catch (e) {
      throw YouTubeApiException('Network error: $e');
    }
  }

  /// An OAuth-authenticated POST/DELETE: on a 401 the access
  /// token is refreshed once and the request retried.
  Future<http.Response> _postAuthenticated(
    Uri uri, {
    Map<String, Object?>? jsonBody,
    String method = 'POST',
  }) async {
    _requireAccessToken();
    http.Response response =
        await _sendAuthenticated(uri, jsonBody: jsonBody, method: method);
    if (response.statusCode == 401) {
      await _refreshOnce();
      response =
          await _sendAuthenticated(uri, jsonBody: jsonBody, method: method);
    }
    return _check(response);
  }

  Future<http.Response> _sendAuthenticated(
    Uri uri, {
    Map<String, Object?>? jsonBody,
    String method = 'POST',
  }) async {
    final Map<String, String> headers = <String, String>{
      ..._authHeaders,
      if (jsonBody != null) 'Content-Type': 'application/json',
    };
    try {
      if (method == 'DELETE') {
        return await _http.delete(uri, headers: headers);
      }
      return await _http.post(
        uri,
        headers: headers,
        body: jsonBody == null ? null : json.encode(jsonBody),
      );
    } catch (e) {
      throw YouTubeApiException('Network error: $e');
    }
  }

  /// Refreshes the access token once. Needs the OAuth client ID
  /// — the adapter stores it and sets [oauthClientId]. Throws
  /// when there is no client ID or no refresh token.
  Future<void> _refreshOnce() async {
    final String? clientId = oauthClientId;
    if (clientId == null || clientId.isEmpty) {
      throw const YouTubeApiException(
        'Session expired and no OAuth client ID is stored: '
        'log in again.',
      );
    }
    await refreshAccessToken(clientId: clientId);
  }

  http.Response _check(http.Response response) {
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return response;
    }
    throw _errorFrom(response);
  }

  YouTubeApiException _errorFrom(http.Response response) {
    String message = 'YouTube API error (HTTP ${response.statusCode}).';
    try {
      final Object? decoded = json.decode(response.body);
      if (decoded is Map<String, dynamic>) {
        final Object? error = decoded['error'];
        if (error is Map<String, dynamic>) {
          final String? msg = error['message'] as String?;
          if (msg != null && msg.isNotEmpty) message = msg;
          final List<Object?> errors =
              (error['errors'] as List<Object?>?) ?? <Object?>[];
          for (final Object? e in errors) {
            if (e is Map<String, dynamic> &&
                e['reason'] == 'quotaExceeded') {
              message =
                  'YouTube API quota exhausted (10,000 units/day). '
                  'Search costs 100 units per call — wait until '
                  'midnight Pacific, or raise the quota in Google '
                  'Cloud Console.';
              break;
            }
          }
        }
      }
    } catch (_) {
      // Unparseable body: keep the generic message.
    }
    return YouTubeApiException(message, statusCode: response.statusCode);
  }

  dynamic _decode(http.Response response) {
    final http.Response checked = _check(response);
    try {
      return json.decode(checked.body);
    } catch (_) {
      throw const YouTubeApiException(
        'YouTube API returned an unparseable response.',
      );
    }
  }

  List<Object?> _decodeItems(http.Response response) {
    final Object? decoded = _decode(response);
    if (decoded is Map<String, dynamic>) {
      final Object? items = decoded['items'];
      if (items is List<Object?>) return items;
    }
    return <Object?>[];
  }
}
