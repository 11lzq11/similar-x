/// Reddit Data API client: plain HTTPS + JSON over
/// `package:http`.
///
/// Auth is per-user, from the user's own Reddit app — Similar-X
/// ships no shared client ID, so one user's quota can never eat
/// another's:
///
/// 1. reddit.com/prefs/apps > create app > type **installed
///    app** > redirect URI `http://127.0.0.1` (any port; the
///    loopback listener picks an ephemeral one). Copy the client
///    ID shown under the app name and paste it in Similar-X.
/// 2. Login uses OAuth 2.0 with PKCE and a loopback redirect —
///    the code never leaves the device. The access token lives
///    ~1 hour; the client refreshes it once on a 401 and
///    retries. The refresh token is stored encrypted on-device.
///
/// **Manual approval (since Nov 2025):** Reddit's Responsible
/// Builder Policy closed self-service registration — every new
/// app, including free personal ones, needs manual approval
/// (usually 2–4 weeks, sometimes silently refused). Until the
/// app is approved, login and the OAuth feeds fail with a 401.
/// Guest browsing of public subreddits still works through the
/// app-only token or the public JSON fallback below.
///
/// Free tier: **100 requests/minute** per OAuth client,
/// non-commercial use only. Commercial use is $0.24/1,000 calls.
/// Reddit requires a descriptive User-Agent on every request;
/// the one below identifies the app and its repo.
///
/// Guests are not forced to log in. Without a user account the
/// timeline shows r/popular: with a client ID set it is fetched
/// through the app-only OAuth token (client credentials grant,
/// the reliable path); without a client ID it falls back to the
/// public `www.reddit.com/...json` endpoint, which Reddit
/// rate-limits aggressively for unauthenticated requests and may
/// answer 429 — best effort only.
///
/// Reference client: RedReader (official free tier, still
/// maintained).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'reddit_models.dart';

/// Thrown when a Reddit API call fails: missing client ID, wrong
/// credentials, unapproved app, rate limit, network error, or a
/// non-2xx response. [statusCode] is the HTTP status when the
/// server answered, null when the request never reached it.
class RedditApiException implements Exception {
  const RedditApiException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => 'RedditApiException: $message'
      '${statusCode == null ? '' : ' (HTTP $statusCode)'}';
}

/// The Reddit OAuth host: authorize + token endpoints.
const String redditAuthHost = 'www.reddit.com';

/// The Reddit Data API host (OAuth calls only).
const String redditApiHost = 'oauth.reddit.com';

/// The public host for the unauthenticated JSON fallback.
const String redditPublicHost = 'www.reddit.com';

/// Reddit requires a descriptive User-Agent. No Reddit username
/// is invented here — the repo URL is the contact.
const String redditUserAgent =
    'Similar-X/0.1.0 (Flutter; +https://github.com/11lzq11/similar-x)';

/// The OAuth scopes Similar-X asks for: identity, reading,
/// posting, voting, commenting, saving, subscribing, the user's
/// subreddits and inbox. The smallest set that covers the
/// adapter's logged-in capabilities.
const String redditOAuthScope =
    'identity read submit vote comment save subscribe mysubreddits '
    'history privatemessages';

/// Free tier: 100 requests/minute per OAuth client.
const int redditFreeTierRequestsPerMinute = 100;

/// Commercial pricing: $0.24 per 1,000 calls.
const double redditCommercialPricePerThousandCalls = 0.24;

/// The home-feed sorts Reddit offers.
const List<String> redditHomeSorts = <String>[
  'best',
  'hot',
  'new',
  'top',
  'rising',
];

/// The subreddit-feed sorts.
const List<String> redditSubredditSorts = <String>[
  'hot',
  'new',
  'top',
  'rising',
];

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
/// an ephemeral port, waits for Reddit to redirect the browser
/// to `http://127.0.0.1:<port>/?code=...`, captures the code,
/// answers with a small success page and shuts down. [cancel]
/// closes the server without a code (the user closed the browser).
class RedditLoopbackAuthListener {
  RedditLoopbackAuthListener._(this._server, this._completer);

  static Future<RedditLoopbackAuthListener> start() async {
    final HttpServer server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final Completer<String> completer = Completer<String>();
    final RedditLoopbackAuthListener listener =
        RedditLoopbackAuthListener._(server, completer);
    // A silent error handler: cancelling a login nobody is
    // awaiting must not surface as an unhandled async error.
    // Awaiting [code] elsewhere still receives the error.
    unawaited(completer.future.catchError((Object _) => ''));
    server.listen((HttpRequest request) async {
      final String? code = request.uri.queryParameters['code'];
      final String? state = request.uri.queryParameters['state'];
      final String? error = request.uri.queryParameters['error'];
      request.response.headers.contentType = ContentType.html;
      if (code != null && code.isNotEmpty) {
        request.response.write(
          '<html><body><h1>Similar-X</h1>'
          '<p>Reddit login complete — you can close this tab and '
          'return to Similar-X.</p></body></html>',
        );
        await request.response.close();
        await server.close(force: true);
        if (!completer.isCompleted) {
          listener._state = state;
          completer.complete(code);
        }
      } else {
        request.response.write(
          '<html><body><h1>Similar-X</h1>'
          '<p>Reddit login failed'
          '${error == null ? '' : ': $error'}. '
          'You can close this tab and try again in Similar-X.'
          '</p></body></html>',
        );
        await request.response.close();
        await server.close(force: true);
        if (!completer.isCompleted) {
          completer.completeError(
            RedditApiException(
              'Login failed: Reddit returned '
              '${error ?? 'an unknown error'}.',
            ),
          );
        }
      }
    });
    return listener;
  }

  final HttpServer _server;
  final Completer<String> _completer;
  String? _state;

  /// The redirect URI Reddit must send the browser to. Register
  /// `http://127.0.0.1` as the redirect URI in the Reddit app
  /// settings; the port is ephemeral and Reddit ignores it.
  String get redirectUri => 'http://127.0.0.1:${_server.port}';

  /// Completes with the authorization code when Reddit redirects
  /// here, or with a [RedditApiException] on error/cancel.
  Future<String> get code => _completer.future;

  /// The `state` value Reddit echoed back with the code, or
  /// null when the redirect carried none. The adapter compares
  /// it with the state it sent, to prove the redirect belongs
  /// to this login attempt.
  String? get state => _state;

  /// Closes the listener without a code (user gave up). The
  /// pending [code] future completes with an error.
  Future<void> cancel() async {
    await _server.close(force: true);
    if (!_completer.isCompleted) {
      _completer.completeError(
        const RedditApiException('Login cancelled.'),
      );
    }
  }
}

/// One Reddit account's API client.
///
/// The client holds no credential by itself: [clientId] /
/// [accessToken] / [refreshToken] are set by the adapter after
/// the user enters them and cleared on logout. Calls without a
/// user token use the app-only token (guest) or the public JSON
/// fallback — see [listPopularGuest] and [listSubredditPublic].
class RedditClient {
  RedditClient({this.clientId, http.Client? httpClient})
      : _http = httpClient ?? http.Client();

  /// The user's installed-app client ID (reddit.com/prefs/apps).
  /// Needed for every OAuth flow, including guest app-only auth.
  String? clientId;

  /// The OAuth access token. Set after login; cleared on logout.
  String? accessToken;

  /// The OAuth refresh token. Set after login; cleared on logout.
  String? refreshToken;

  /// Called after an access-token refresh so the adapter can
  /// persist the new tokens. Null in tests that do not care
  /// about persistence.
  Future<void> Function(RedditTokens tokens)? onTokensRefreshed;

  final http.Client _http;

  String? _appOnlyToken;
  DateTime? _appOnlyExpiresAt;

  /// Whether the current access token is an app-only (guest)
  /// token rather than a user token. App-only tokens can read
  /// public content but cannot post, vote or comment.
  bool get hasAppOnlyToken =>
      _appOnlyToken != null &&
      _appOnlyExpiresAt != null &&
      DateTime.now().isBefore(_appOnlyExpiresAt!);

  Map<String, String> get _userAgentHeader =>
      <String, String>{'User-Agent': redditUserAgent};

  String _basicAuth(String clientId) =>
      'Basic ${base64.encode(utf8.encode('$clientId:'))}';

  /// The URL the user opens in a browser to authorize Similar-X.
  /// Reddit redirects to [redirectUri] with `?code=...` after
  /// approval; the adapter captures it with a
  /// [RedditLoopbackAuthListener]. `duration=permanent` asks for
  /// a refresh token.
  Uri buildAuthorizeUrl({
    required String clientId,
    required String codeChallenge,
    required String redirectUri,
    required String state,
  }) =>
      Uri.https(redditAuthHost, '/api/v1/authorize', <String, String>{
        'client_id': clientId,
        'response_type': 'code',
        'state': state,
        'redirect_uri': redirectUri,
        'duration': 'permanent',
        'scope': redditOAuthScope,
        'code_challenge': codeChallenge,
        'code_challenge_method': 'S256',
      });

  /// Exchanges the authorization code for access + refresh
  /// tokens. Installed apps have no client secret: the client
  /// ID is sent as HTTP Basic auth with an empty password, and
  /// PKCE ([codeVerifier]) proves the exchange belongs to this
  /// login. Throws when Reddit rejects the code — for example
  /// when the app has not passed manual approval yet.
  Future<RedditTokens> exchangeCode({
    required String code,
    required String clientId,
    required String codeVerifier,
    required String redirectUri,
  }) async {
    final http.Response response = await _http.post(
      Uri.https(redditAuthHost, '/api/v1/access_token'),
      headers: <String, String>{
        ..._userAgentHeader,
        'Authorization': _basicAuth(clientId),
      },
      body: <String, String>{
        'grant_type': 'authorization_code',
        'code': code,
        'redirect_uri': redirectUri,
        'code_verifier': codeVerifier,
      },
    );
    final RedditTokens tokens = RedditTokens.fromJson(
      _decode(response) as Map<String, dynamic>,
    );
    if (!tokens.isValid) {
      throw const RedditApiException(
        'Token exchange failed: no access token returned. If the '
        'Reddit app is new, it may still be waiting for manual '
        'approval (since Nov 2025).',
      );
    }
    _applyTokens(tokens);
    return tokens;
  }

  /// Refreshes the access token with the stored refresh token
  /// and applies the new tokens. Throws when there is no refresh
  /// token or Reddit rejects it — the user has to log in again.
  Future<RedditTokens> refreshAccessToken({
    required String clientId,
  }) async {
    final String? refresh = refreshToken;
    if (refresh == null || refresh.isEmpty) {
      throw const RedditApiException(
        'Session expired: log in again.',
      );
    }
    final http.Response response = await _http.post(
      Uri.https(redditAuthHost, '/api/v1/access_token'),
      headers: <String, String>{
        ..._userAgentHeader,
        'Authorization': _basicAuth(clientId),
      },
      body: <String, String>{
        'grant_type': 'refresh_token',
        'refresh_token': refresh,
      },
    );
    final RedditTokens tokens = RedditTokens.fromJson(
      _decode(response) as Map<String, dynamic>,
    );
    if (!tokens.isValid) {
      throw const RedditApiException(
        'Session refresh failed: log in again.',
      );
    }
    // Reddit does not always return a fresh refresh token; keep
    // the old one when the response has none.
    final RedditTokens kept = RedditTokens(
      accessToken: tokens.accessToken,
      tokenType: tokens.tokenType,
      expiresInSeconds: tokens.expiresInSeconds,
      refreshToken: tokens.refreshToken ?? refresh,
      scope: tokens.scope,
    );
    _applyTokens(kept);
    await onTokensRefreshed?.call(kept);
    return kept;
  }

  /// Fetches an app-only (guest) token with the client
  /// credentials grant. No user, no refresh token — it only
  /// reads public content and lives about an hour. The token
  /// is cached in memory until shortly before expiry.
  Future<String> ensureAppOnlyToken({
    required String clientId,
  }) async {
    if (hasAppOnlyToken) return _appOnlyToken!;
    final http.Response response = await _http.post(
      Uri.https(redditAuthHost, '/api/v1/access_token'),
      headers: <String, String>{
        ..._userAgentHeader,
        'Authorization': _basicAuth(clientId),
      },
      body: <String, String>{'grant_type': 'client_credentials'},
    );
    final RedditTokens tokens = RedditTokens.fromJson(
      _decode(response) as Map<String, dynamic>,
    );
    if (!tokens.isValid) {
      throw const RedditApiException(
        'Guest token failed: no access token returned.',
      );
    }
    _appOnlyToken = tokens.accessToken;
    _appOnlyExpiresAt = DateTime.now().add(
      Duration(seconds: tokens.expiresInSeconds - 60),
    );
    return tokens.accessToken;
  }

  void _applyTokens(RedditTokens tokens) {
    accessToken = tokens.accessToken;
    if (tokens.refreshToken != null &&
        tokens.refreshToken!.isNotEmpty) {
      refreshToken = tokens.refreshToken;
    }
  }

  /// Clears the in-memory app-only token (logout also clears
  /// the user tokens through the adapter).
  void clearAppOnlyToken() {
    _appOnlyToken = null;
    _appOnlyExpiresAt = null;
  }

  /// The logged-in user's identity. OAuth only.
  Future<RedditUser> getMe() async {
    final http.Response response = await _getAuthenticated(
      Uri.https(redditApiHost, '/api/v1/me'),
    );
    return RedditUser.fromJson(
      _decode(response) as Map<String, dynamic>,
    );
  }

  /// The home feed: /best by default (the user's subscribed
  /// subreddits, ranked). OAuth only — guests use
  /// [listPopularGuest] instead.
  Future<List<RedditPost>> listHome({
    String sort = 'best',
    int limit = 25,
  }) async {
    if (!redditHomeSorts.contains(sort)) {
      throw RedditApiException('Invalid home sort: "$sort".');
    }
    final http.Response response = await _getAuthenticated(
      Uri.https(redditApiHost, '/$sort', <String, String>{
        'limit': limit.toString(),
      }),
    );
    return _decodePosts(response);
  }

  /// A subreddit feed (hot/new/top/rising). Works with a user
  /// token, an app-only token, or no credentials at all (the
  /// public JSON fallback).
  Future<List<RedditPost>> listSubreddit({
    required String subreddit,
    String sort = 'hot',
    int limit = 25,
  }) async {
    if (!redditSubredditSorts.contains(sort)) {
      throw RedditApiException('Invalid subreddit sort: "$sort".');
    }
    final String sub = _cleanSubreddit(subreddit);
    final http.Response response = await _getReadable(
      apiPath: '/r/$sub/$sort',
      publicPath: '/r/$sub/$sort.json',
      query: <String, String>{'limit': limit.toString()},
    );
    return _decodePosts(response);
  }

  /// The guest home feed: r/popular, hot. Uses the app-only
  /// token when a client ID is set; falls back to the public
  /// JSON endpoint otherwise.
  Future<List<RedditPost>> listPopularGuest({int limit = 25}) async {
    final String? id = clientId;
    if (id == null || id.isEmpty) {
      return listPopularPublic(limit: limit);
    }
    final http.Response response = await _getAppOnly(
      Uri.https(redditApiHost, '/r/popular/hot', <String, String>{
        'limit': limit.toString(),
      }),
    );
    return _decodePosts(response);
  }

  /// The public JSON fallback for r/popular (no credentials at
  /// all). Best effort: Reddit rate-limits unauthenticated
  /// requests hard and may answer 429.
  Future<List<RedditPost>> listPopularPublic({int limit = 25}) async {
    final http.Response response = await _getPublic(
      Uri.https(redditPublicHost, '/r/popular/hot.json',
          <String, String>{'limit': limit.toString()}),
    );
    return _decodePosts(response);
  }

  /// The public JSON fallback for one subreddit (no credentials
  /// at all). Best effort — see [listPopularPublic].
  Future<List<RedditPost>> listSubredditPublic({
    required String subreddit,
    String sort = 'hot',
    int limit = 25,
  }) async {
    if (!redditSubredditSorts.contains(sort)) {
      throw RedditApiException('Invalid subreddit sort: "$sort".');
    }
    final String sub = _cleanSubreddit(subreddit);
    final http.Response response = await _getPublic(
      Uri.https(redditPublicHost, '/r/$sub/$sort.json',
          <String, String>{'limit': limit.toString()}),
    );
    return _decodePosts(response);
  }

  /// Details for one subreddit, including subscriber count.
  /// Works with a user token, an app-only token, or no
  /// credentials at all (the public JSON fallback).
  Future<RedditSubreddit> getSubredditAbout(String subreddit) async {
    final String sub = _cleanSubreddit(subreddit);
    final http.Response response = await _getReadable(
      apiPath: '/r/$sub/about',
      publicPath: '/r/$sub/about.json',
    );
    return RedditSubreddit.fromJson(
      _decode(response) as Map<String, dynamic>,
    );
  }

  /// Searches posts by keyword. Works with a user token, an
  /// app-only token, or no credentials at all (the public JSON
  /// fallback).
  Future<List<RedditPost>> searchPosts(
    String query, {
    int limit = 25,
  }) async {
    final String q = query.trim();
    if (q.isEmpty) {
      throw const RedditApiException('Search query must not be empty.');
    }
    final Map<String, String> params = <String, String>{
      'q': q,
      'type': 'link',
      'sort': 'relevance',
      'limit': limit.toString(),
    };
    final http.Response response = await _getReadable(
      apiPath: '/search',
      publicPath: '/search.json',
      query: params,
    );
    return _decodePosts(response);
  }

  /// Searches subreddits by name. Works with a user token, an
  /// app-only token, or no credentials at all (the public JSON
  /// fallback).
  Future<List<RedditSubreddit>> searchSubreddits(
    String query, {
    int limit = 25,
  }) async {
    final String q = query.trim();
    if (q.isEmpty) {
      throw const RedditApiException('Search query must not be empty.');
    }
    final Map<String, String> params = <String, String>{
      'q': q,
      'type': 'sr',
      'sort': 'relevance',
      'limit': limit.toString(),
    };
    final http.Response response = await _getReadable(
      apiPath: '/search',
      publicPath: '/search.json',
      query: params,
    );
    final List<Object?> items = _decodeChildren(response, 't5');
    return items
        .whereType<Map<String, dynamic>>()
        .map(RedditSubreddit.fromJson)
        .where((RedditSubreddit s) => s.isValid)
        .toList();
  }

  /// The comments on a post, newest first by default. Works
  /// with a user token, an app-only token, or no credentials at
  /// all (the public JSON fallback). The response is a two-item
  /// list: the post listing, then the comment listing.
  Future<List<RedditComment>> listComments({
    required String subreddit,
    required String postId,
    String sort = 'top',
    int limit = 100,
  }) async {
    final String sub = _cleanSubreddit(subreddit);
    final String id = postId.startsWith('t3_')
        ? postId.substring(3)
        : postId;
    final Map<String, String> params = <String, String>{
      'sort': sort,
      'limit': limit.toString(),
    };
    final http.Response response = await _getReadable(
      apiPath: '/r/$sub/comments/$id',
      publicPath: '/r/$sub/comments/$id.json',
      query: params,
    );
    final Object? decoded = _decode(response);
    if (decoded is! List<Object?> || decoded.length < 2) {
      return <RedditComment>[];
    }
    final Object? commentsListing = decoded[1];
    if (commentsListing is! Map<String, dynamic>) {
      return <RedditComment>[];
    }
    final List<Object?> items =
        _childrenOf(commentsListing, 't1');
    return items
        .whereType<Map<String, dynamic>>()
        .map(RedditComment.fromJson)
        .where((RedditComment c) => c.isValid)
        .toList();
  }

  /// One post by fullname (`t3_...`) or short id. Works with a
  /// user token, an app-only token, or no credentials at all —
  /// the public fallback reads `/comments/<id>.json` and takes
  /// the post out of its first listing.
  Future<RedditPost?> getPost(String fullnameOrId) async {
    final String shortId = fullnameOrId.startsWith('t3_')
        ? fullnameOrId.substring(3)
        : fullnameOrId;
    final bool hasUserToken =
        accessToken != null && accessToken!.isNotEmpty;
    final String? id = clientId;
    if (hasUserToken || (id != null && id.isNotEmpty)) {
      final http.Response response = hasUserToken
          ? await _getAuthenticated(
              Uri.https(redditApiHost, '/api/info',
                  <String, String>{'id': 't3_$shortId'}),
            )
          : await _getAppOnly(
              Uri.https(redditApiHost, '/api/info',
                  <String, String>{'id': 't3_$shortId'}),
            );
      final List<RedditPost> posts = _decodePosts(response);
      return posts.isEmpty ? null : posts.first;
    }
    final http.Response response = await _getPublic(
      Uri.https(redditPublicHost, '/comments/$shortId.json'),
    );
    final Object? decoded = _decode(response);
    if (decoded is List<Object?> && decoded.isNotEmpty) {
      final Object? first = decoded.first;
      if (first is Map<String, dynamic>) {
        final List<Object?> items = _childrenOf(first, 't3');
        final List<RedditPost> posts = items
            .whereType<Map<String, dynamic>>()
            .map(RedditPost.fromJson)
            .where((RedditPost p) => p.isValid)
            .toList();
        return posts.isEmpty ? null : posts.first;
      }
    }
    return null;
  }

  /// Submits a post. [kind] is `self` (text) or `link`.
  /// OAuth only. Returns the new post's fullname (`t3_...`).
  Future<String> submitPost({
    required String subreddit,
    required String kind,
    required String title,
    String? text,
    String? url,
  }) async {
    if (kind != 'self' && kind != 'link') {
      throw RedditApiException('Invalid post kind: "$kind".');
    }
    if (title.trim().isEmpty) {
      throw const RedditApiException('Post title must not be empty.');
    }
    final Map<String, String> body = <String, String>{
      'kind': kind,
      'sr': _cleanSubreddit(subreddit),
      'title': title.trim(),
      'api_type': 'json',
    };
    if (kind == 'self') {
      body['text'] = text ?? '';
    } else {
      if (url == null || url.trim().isEmpty) {
        throw const RedditApiException(
          'Link posts need a URL.',
        );
      }
      body['url'] = url.trim();
    }
    final http.Response response = await _postAuthenticated(
      Uri.https(redditApiHost, '/api/submit'),
      body: body,
    );
    final Object? decoded = _decode(response);
    final String? name = _jsonApiName(decoded);
    if (name == null || name.isEmpty) {
      throw const RedditApiException(
        'Submit failed: Reddit returned no post id.',
      );
    }
    return name;
  }

  /// Votes on a post or comment: 1 = upvote, -1 = downvote,
  /// 0 = clear. OAuth only.
  Future<void> vote({
    required String fullname,
    required int direction,
  }) async {
    if (direction != 1 && direction != -1 && direction != 0) {
      throw RedditApiException('Invalid vote direction: $direction.');
    }
    await _postAuthenticated(
      Uri.https(redditApiHost, '/api/vote'),
      body: <String, String>{
        'id': fullname,
        'dir': direction.toString(),
      },
    );
  }

  /// Posts a comment on a post or another comment. [thingId]
  /// is the parent fullname (`t3_...` or `t1_...`). OAuth only.
  /// Returns the created comment.
  Future<RedditComment> comment({
    required String thingId,
    required String text,
  }) async {
    if (text.trim().isEmpty) {
      throw const RedditApiException('Comment must not be empty.');
    }
    final http.Response response = await _postAuthenticated(
      Uri.https(redditApiHost, '/api/comment'),
      body: <String, String>{
        'thing_id': thingId,
        'text': text,
        'api_type': 'json',
      },
    );
    final Object? decoded = _decode(response);
    final Map<String, dynamic>? data = _jsonApiData(decoded);
    if (data == null) {
      throw const RedditApiException(
        'Comment failed: Reddit returned no comment.',
      );
    }
    final Object? things = data['things'];
    if (things is List<Object?>) {
      for (final Object? thing in things) {
        if (thing is Map<String, dynamic> &&
            thing['kind'] == 't1') {
          final Object? thingData = thing['data'];
          if (thingData is Map<String, dynamic>) {
            final RedditComment created =
                RedditComment.fromJson(thingData);
            if (created.isValid) return created;
          }
        }
      }
    }
    throw const RedditApiException(
      'Comment failed: Reddit returned no comment.',
    );
  }

  /// Saves a post or comment. OAuth only.
  Future<void> save({required String fullname}) async {
    await _postAuthenticated(
      Uri.https(redditApiHost, '/api/save'),
      body: <String, String>{'id': fullname},
    );
  }

  /// Unsaves a post or comment. OAuth only.
  Future<void> unsave({required String fullname}) async {
    await _postAuthenticated(
      Uri.https(redditApiHost, '/api/unsave'),
      body: <String, String>{'id': fullname},
    );
  }

  /// Subscribes (`sub`) or unsubscribes (`unsub`) from a
  /// subreddit. OAuth only.
  Future<void> subscribe({
    required String subreddit,
    required String action,
  }) async {
    if (action != 'sub' && action != 'unsub') {
      throw RedditApiException(
        'Invalid subscribe action: "$action".',
      );
    }
    await _postAuthenticated(
      Uri.https(redditApiHost, '/api/subscribe'),
      body: <String, String>{
        'action': action,
        'sr_name': _cleanSubreddit(subreddit),
      },
    );
  }

  /// The subreddits the user subscribes to. OAuth only.
  Future<List<RedditSubreddit>> listMySubreddits({
    int limit = 100,
  }) async {
    final http.Response response = await _getAuthenticated(
      Uri.https(redditApiHost, '/subreddits/mine/subscriber',
          <String, String>{'limit': limit.toString()}),
    );
    final List<Object?> items = _decodeChildren(response, 't5');
    return items
        .whereType<Map<String, dynamic>>()
        .map(RedditSubreddit.fromJson)
        .where((RedditSubreddit s) => s.isValid)
        .toList();
  }

  /// The user's inbox: comment replies and private messages,
  /// newest first. OAuth only.
  Future<List<RedditMessage>> listInbox({int limit = 25}) async {
    final http.Response response = await _getAuthenticated(
      Uri.https(redditApiHost, '/message/inbox', <String, String>{
        'limit': limit.toString(),
      }),
    );
    final List<Object?> items = _decodeChildren(response, null);
    return items
        .whereType<Map<String, dynamic>>()
        .map(RedditMessage.fromJson)
        .where((RedditMessage m) => m.isValid)
        .toList();
  }

  /// The user's saved posts. OAuth only.
  Future<List<RedditPost>> listSaved({
    required String username,
    int limit = 25,
  }) async {
    final http.Response response = await _getAuthenticated(
      Uri.https(
        redditApiHost,
        '/user/$username/saved',
        <String, String>{'limit': limit.toString()},
      ),
    );
    return _decodePosts(response);
  }

  /// The user's upvoted posts. OAuth only.
  Future<List<RedditPost>> listUpvoted({
    required String username,
    int limit = 25,
  }) async {
    final http.Response response = await _getAuthenticated(
      Uri.https(
        redditApiHost,
        '/user/$username/upvoted',
        <String, String>{'limit': limit.toString()},
      ),
    );
    return _decodePosts(response);
  }

  String _cleanSubreddit(String subreddit) {
    String sub = subreddit.trim();
    if (sub.toLowerCase().startsWith('r/')) sub = sub.substring(2);
    return sub;
  }

  void _requireAccessToken() {
    final String? token = accessToken;
    if (token == null || token.isEmpty) {
      throw const RedditApiException(
        'Log in to Reddit first (OAuth).',
      );
    }
  }

  void _requireClientId() {
    final String? id = clientId;
    if (id == null || id.isEmpty) {
      throw const RedditApiException(
        'No Reddit client ID set. Create an installed app at '
        'reddit.com/prefs/apps and save its client ID in '
        'Similar-X first.',
      );
    }
  }

  /// A readable GET, routed by what credentials exist: the
  /// user token when logged in, the app-only token when a
  /// client ID is set, and the public JSON endpoint ([publicPath]
  /// on [redditPublicHost]) when there are no credentials at
  /// all. The public path is best effort — Reddit rate-limits
  /// unauthenticated requests hard.
  Future<http.Response> _getReadable({
    required String apiPath,
    required String publicPath,
    Map<String, String>? query,
  }) async {
    if (accessToken != null && accessToken!.isNotEmpty) {
      return _getAuthenticated(
        Uri.https(redditApiHost, apiPath, query),
      );
    }
    final String? id = clientId;
    if (id != null && id.isNotEmpty) {
      return _getAppOnly(
        Uri.https(redditApiHost, apiPath, query),
      );
    }
    return _getPublic(
      Uri.https(redditPublicHost, publicPath, query),
    );
  }

  /// An OAuth-authenticated GET: on a 401 the access token is
  /// refreshed once and the request retried.
  Future<http.Response> _getAuthenticated(Uri uri) async {
    _requireAccessToken();
    http.Response response = await _getRaw(uri, _bearerHeaders());
    if (response.statusCode == 401) {
      await _refreshOnce();
      response = await _getRaw(uri, _bearerHeaders());
    }
    return _check(response);
  }

  /// An app-only GET: ensures a guest token first (cached until
  /// shortly before expiry); on a 401 the token is re-fetched
  /// once and the request retried.
  Future<http.Response> _getAppOnly(Uri uri) async {
    _requireClientId();
    String token = await ensureAppOnlyToken(clientId: clientId!);
    http.Response response = await _getRaw(
      uri,
      _bearerHeaders(token),
    );
    if (response.statusCode == 401) {
      clearAppOnlyToken();
      token = await ensureAppOnlyToken(clientId: clientId!);
      response = await _getRaw(uri, _bearerHeaders(token));
    }
    return _check(response);
  }

  /// A plain GET with only the User-Agent header (public JSON
  /// fallback). No auth, no retry.
  Future<http.Response> _getPublic(Uri uri) async {
    final http.Response response = await _getRaw(uri, const <String, String>{});
    return _check(response);
  }

  Map<String, String> _bearerHeaders([String? token]) {
    final String? use = token ?? accessToken;
    return <String, String>{
      ..._userAgentHeader,
      if (use != null && use.isNotEmpty) 'Authorization': 'Bearer $use',
    };
  }

  Future<http.Response> _getRaw(
    Uri uri,
    Map<String, String> headers,
  ) async {
    try {
      return await _http.get(uri, headers: headers);
    } catch (e) {
      throw RedditApiException('Network error: $e');
    }
  }

  /// An OAuth-authenticated POST (form-encoded, like Reddit
  /// expects): on a 401 the access token is refreshed once and
  /// the request retried.
  Future<http.Response> _postAuthenticated(
    Uri uri, {
    required Map<String, String> body,
  }) async {
    _requireAccessToken();
    http.Response response = await _sendAuthenticated(uri, body);
    if (response.statusCode == 401) {
      await _refreshOnce();
      response = await _sendAuthenticated(uri, body);
    }
    return _check(response);
  }

  Future<http.Response> _sendAuthenticated(
    Uri uri,
    Map<String, String> body,
  ) async {
    try {
      return await _http.post(
        uri,
        headers: _bearerHeaders(),
        body: body,
      );
    } catch (e) {
      throw RedditApiException('Network error: $e');
    }
  }

  /// Refreshes the access token once. Needs the client ID —
  /// the adapter stores it and sets [clientId]. Throws when
  /// there is no client ID or no refresh token.
  Future<void> _refreshOnce() async {
    final String? id = clientId;
    if (id == null || id.isEmpty) {
      throw const RedditApiException(
        'Session expired and no Reddit client ID is stored: '
        'log in again.',
      );
    }
    await refreshAccessToken(clientId: id);
  }

  http.Response _check(http.Response response) {
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return response;
    }
    throw _errorFrom(response);
  }

  RedditApiException _errorFrom(http.Response response) {
    String message =
        'Reddit API error (HTTP ${response.statusCode}).';
    if (response.statusCode == 401) {
      message =
          'Reddit rejected the request (HTTP 401). The token may '
          'be expired or revoked — or the Reddit app may still '
          'be waiting for manual approval (required since '
          'Nov 2025).';
    } else if (response.statusCode == 403) {
      message =
          'Reddit refused the request (HTTP 403). The app may '
          'lack approval, or the account may not have access to '
          'this content.';
    } else if (response.statusCode == 429) {
      message =
          'Reddit rate limit hit (HTTP 429). The free tier '
          'allows 100 requests/minute per OAuth client — wait a '
          'minute and try again.';
    }
    try {
      final Object? decoded = json.decode(response.body);
      if (decoded is Map<String, dynamic>) {
        final Object? msg = decoded['message'];
        if (msg is String && msg.isNotEmpty) message = msg;
        final Object? error = decoded['error'];
        if (error is String && error.isNotEmpty) {
          message = '$message ($error)';
        }
        // /api/submit and /api/comment report errors as
        // {"json": {"errors": [["CODE", "message", "field"]]}}.
        final Object? jsonApi = decoded['json'];
        if (jsonApi is Map<String, dynamic>) {
          final Object? errors = jsonApi['errors'];
          if (errors is List<Object?> && errors.isNotEmpty) {
            final Object? first = errors.first;
            if (first is List<Object?> && first.length >= 2) {
              final Object? text = first[1];
              if (text is String && text.isNotEmpty) {
                message = text;
              }
            }
          }
        }
      }
    } catch (_) {
      // Unparseable body: keep the message above.
    }
    return RedditApiException(message, statusCode: response.statusCode);
  }

  dynamic _decode(http.Response response) {
    final http.Response checked = _check(response);
    try {
      return json.decode(checked.body);
    } catch (_) {
      throw const RedditApiException(
        'Reddit API returned an unparseable response.',
      );
    }
  }

  /// Children of a Listing response, optionally filtered by
  /// [kind] (`t3`, `t1`, `t5`, `t4`). Each entry is the child's
  /// `data` map.
  List<Object?> _decodeChildren(
    http.Response response, [
    String? kind,
  ]) {
    final Object? decoded = _decode(response);
    if (decoded is Map<String, dynamic>) {
      return _childrenOf(decoded, kind);
    }
    return <Object?>[];
  }

  List<Object?> _childrenOf(
    Map<String, dynamic> listing, [
    String? kind,
  ]) {
    final Object? data = listing['data'];
    if (data is! Map<String, dynamic>) return <Object?>[];
    final Object? children = data['children'];
    if (children is! List<Object?>) return <Object?>[];
    final List<Object?> result = <Object?>[];
    for (final Object? child in children) {
      if (child is! Map<String, dynamic>) continue;
      if (kind != null && child['kind'] != kind) continue;
      final Object? childData = child['data'];
      if (childData != null) result.add(childData);
    }
    return result;
  }

  List<RedditPost> _decodePosts(http.Response response) {
    final List<Object?> items = _decodeChildren(response, 't3');
    return items
        .whereType<Map<String, dynamic>>()
        .map(RedditPost.fromJson)
        .where((RedditPost p) => p.isValid)
        .toList();
  }

  /// The `data` map of a `{"json": {"data": ...}}` response
  /// (submit / comment), or null when Reddit reported errors.
  Map<String, dynamic>? _jsonApiData(Object? decoded) {
    if (decoded is Map<String, dynamic>) {
      final Object? jsonApi = decoded['json'];
      if (jsonApi is Map<String, dynamic>) {
        final Object? errors = jsonApi['errors'];
        if (errors is List<Object?> && errors.isNotEmpty) {
          return null;
        }
        final Object? data = jsonApi['data'];
        if (data is Map<String, dynamic>) return data;
      }
    }
    return null;
  }

  /// The new post fullname from a submit response.
  String? _jsonApiName(Object? decoded) {
    final Map<String, dynamic>? data = _jsonApiData(decoded);
    if (data == null) return null;
    final Object? name = data['name'];
    return name is String ? name : null;
  }
}
