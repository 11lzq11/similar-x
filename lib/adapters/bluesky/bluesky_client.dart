/// Bluesky / AT Protocol client: plain HTTPS + JSON over
/// `package:http`.
///
/// Architecture (this is how the official client works too):
/// * the **public AppView** (`public.api.bsky.app`) serves feeds,
///   profiles, search and threads. Public reads need no login;
///   logged-in users pass their access JWT so the AppView can fill
///   in viewer state (liked / reposted by me).
/// * the **PDS** (default `bsky.social`) serves sessions and record
///   writes: `createSession`, `refreshSession`, `createRecord`,
///   `deleteRecord`.
///
/// Login uses an App Password, never the account password: the user
/// makes one at Bluesky Settings > Privacy and security > App
/// passwords. The access JWT expires after about two hours; on a
/// 401 `ExpiredToken` the client refreshes the session once and
/// retries the request, then tells the adapter (via
/// [onSessionRefreshed]) so the new tokens are persisted.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

import 'bluesky_models.dart';

/// Thrown when a Bluesky API call fails: bad handle, wrong App
/// Password, network error, or a non-2xx response. [statusCode] is
/// the HTTP status when the server answered, null when the request
/// never reached it.
class BlueskyApiException implements Exception {
  const BlueskyApiException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() =>
      'BlueskyApiException: $message'
      '${statusCode == null ? '' : ' (HTTP $statusCode)'}';
}

/// The public AppView host: feeds, profiles, search, threads.
const String blueskyPublicAppView = 'public.api.bsky.app';

/// The default PDS host. Most accounts live on bsky.social; users
/// on another PDS change it in settings (see
/// [BlueskyAdapter.setService]).
const String blueskyDefaultService = 'bsky.social';

/// The "Discover" (What's Hot) feed, used as the guest timeline.
const String blueskyDiscoverFeedUri =
    'at://did:plc:z72i7hdynmk6r22z27h6tvur/feed/whats-hot';

/// Normalizes a user-typed Bluesky handle: strips a leading `@`
/// and whitespace, lowercases. Accepts DIDs as-is. Throws
/// [BlueskyApiException] for anything that is not a plausible
/// handle or DID.
String normalizeBlueskyHandle(String input) {
  String handle = input.trim().toLowerCase();
  if (handle.startsWith('@')) handle = handle.substring(1);
  if (handle.isEmpty || handle.contains(RegExp(r'\s'))) {
    throw BlueskyApiException(
      'Not a valid Bluesky handle: "$input".',
    );
  }
  if (handle.startsWith('did:')) return handle;
  if (!handle.contains('.') ||
      !RegExp(r'^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$').hasMatch(handle)) {
    throw BlueskyApiException(
      'Not a valid Bluesky handle: "$input". '
      'Enter your handle, e.g. alice.bsky.social',
    );
  }
  return handle;
}

/// Normalizes a user-typed PDS host: `https://bsky.social/` ->
/// `bsky.social`. Empty input falls back to the default service.
/// Throws [BlueskyApiException] for anything that is not a
/// plausible host.
String normalizeBlueskyService(String input) {
  String host = input.trim().toLowerCase();
  host = host.replaceFirst(RegExp(r'^https?://'), '');
  host = host.replaceAll(RegExp(r'/.*$'), '');
  if (host.isEmpty) return blueskyDefaultService;
  if (host.contains(RegExp(r'\s')) || !host.contains('.')) {
    throw BlueskyApiException(
      'Not a valid PDS host: "$input". '
      'Enter just the host, e.g. bsky.social',
    );
  }
  return host;
}

/// One Bluesky account's API client.
///
/// The client holds no token by itself: [accessJwt] /
/// [refreshJwt] are set by the adapter after login and cleared on
/// logout. Calls without a token work for public endpoints —
/// guest mode.
class BlueskyClient {
  BlueskyClient({
    String service = blueskyDefaultService,
    http.Client? httpClient,
  })  : service = normalizeBlueskyService(service),
        _http = httpClient ?? http.Client();

  /// The PDS host this client talks to. Settable so the adapter
  /// can point an injected (test) client at a new service.
  String service;

  String? accessJwt;
  String? refreshJwt;
  String? did;
  String? handle;

  /// Called after a session refresh so the adapter can persist the
  /// new tokens. Null in tests that do not care about persistence.
  Future<void> Function(BlueskySession session)? onSessionRefreshed;

  final http.Client _http;

  Uri _pdsUri(String method, [Map<String, String>? query]) =>
      Uri.https(
        service,
        '/xrpc/$method',
        query == null || query.isEmpty ? null : query,
      );

  Uri _appViewUri(String method, [Map<String, String>? query]) =>
      Uri.https(
        blueskyPublicAppView,
        '/xrpc/$method',
        query == null || query.isEmpty ? null : query,
      );

  Map<String, String> get _authHeaders {
    final String? token = accessJwt;
    if (token == null || token.isEmpty) return const <String, String>{};
    return <String, String>{'Authorization': 'Bearer $token'};
  }

  /// Creates a session with a handle (or DID) and an App Password.
  /// The account password must NOT be used here.
  Future<BlueskySession> createSession({
    required String identifier,
    required String password,
  }) async {
    final http.Response response = await _post(
      _pdsUri('com.atproto.server.createSession'),
      jsonBody: <String, Object?>{
        'identifier': identifier,
        'password': password,
      },
    );
    final BlueskySession session = BlueskySession.fromJson(
      _decode(response) as Map<String, dynamic>,
    );
    if (!session.isValid) {
      throw const BlueskyApiException(
        'Login failed: the server did not return a session.',
      );
    }
    _applySession(session);
    return session;
  }

  /// Refreshes the session with the stored refresh JWT and applies
  /// the new tokens. Throws when there is no refresh token or the
  /// server rejects it — the user has to log in again then.
  Future<BlueskySession> refreshSession() async {
    final String? refresh = refreshJwt;
    if (refresh == null || refresh.isEmpty) {
      throw const BlueskyApiException(
        'Session expired: log in again.',
      );
    }
    final http.Response response = await _post(
      _pdsUri('com.atproto.server.refreshSession'),
      headers: <String, String>{'Authorization': 'Bearer $refresh'},
    );
    final BlueskySession session = BlueskySession.fromJson(
      _decode(response) as Map<String, dynamic>,
    );
    if (!session.isValid) {
      throw const BlueskyApiException(
        'Session refresh failed: log in again.',
      );
    }
    _applySession(session);
    await onSessionRefreshed?.call(session);
    return session;
  }

  void _applySession(BlueskySession session) {
    accessJwt = session.accessJwt;
    refreshJwt = session.refreshJwt;
    did = session.did;
    handle = session.handle;
  }

  /// The home timeline: posts from accounts the user follows.
  /// AppView, authenticated.
  Future<List<BlueskyFeedView>> homeTimeline({int limit = 20}) async {
    final http.Response response = await _get(
      _appViewUri('app.bsky.feed.getTimeline', <String, String>{
        'limit': limit.toString(),
      }),
      authenticated: true,
    );
    return _decodeFeed(response);
  }

  /// The Discover feed ("What's Hot"): the guest timeline. AppView,
  /// no login needed.
  Future<List<BlueskyFeedView>> discoverFeed({int limit = 20}) async {
    final http.Response response = await _get(
      _appViewUri('app.bsky.feed.getFeed', <String, String>{
        'feed': blueskyDiscoverFeedUri,
        'limit': limit.toString(),
      }),
    );
    return _decodeFeed(response);
  }

  /// Posts by one actor (handle or DID). AppView, works for guests.
  Future<List<BlueskyFeedView>> authorFeed({
    required String actor,
    int limit = 20,
  }) async {
    final http.Response response = await _get(
      _appViewUri('app.bsky.feed.getAuthorFeed', <String, String>{
        'actor': actor,
        'limit': limit.toString(),
      }),
    );
    return _decodeFeed(response);
  }

  /// A profile (handle or DID). AppView, works for guests.
  Future<BlueskyProfile> getProfile(String actor) async {
    final http.Response response = await _get(
      _appViewUri('app.bsky.actor.getProfile', <String, String>{
        'actor': actor,
      }),
    );
    return BlueskyProfile.fromJson(
      _decode(response) as Map<String, dynamic>,
    );
  }

  /// A post thread: the post, its parent chain and replies.
  /// AppView, works for guests.
  Future<BlueskyThreadPost> getThread({
    required String uri,
    int depth = 6,
  }) async {
    final http.Response response = await _get(
      _appViewUri('app.bsky.feed.getPostThread', <String, String>{
        'uri': uri,
        'depth': depth.toString(),
      }),
    );
    final Map<String, dynamic> json =
        _decode(response) as Map<String, dynamic>;
    final Map<String, dynamic>? thread =
        json['thread'] as Map<String, dynamic>?;
    if (thread == null ||
        thread[r'$type'] != 'app.bsky.feed.defs#threadViewPost') {
      throw const BlueskyApiException('Thread not found.');
    }
    return BlueskyThreadPost.fromJson(thread);
  }

  /// Notifications: likes, reposts, follows, mentions, replies.
  /// AppView, authenticated.
  Future<List<BlueskyNotification>> listNotifications({
    int limit = 20,
  }) async {
    final http.Response response = await _get(
      _appViewUri(
        'app.bsky.notification.listNotifications',
        <String, String>{'limit': limit.toString()},
      ),
      authenticated: true,
    );
    final Map<String, dynamic> json =
        _decode(response) as Map<String, dynamic>;
    final List<Object?> list =
        (json['notifications'] as List<Object?>?) ?? const <Object?>[];
    return list
        .whereType<Map<String, dynamic>>()
        .map(BlueskyNotification.fromJson)
        .toList();
  }

  /// Searches accounts by name or handle. AppView, works for guests.
  Future<List<BlueskyProfile>> searchActors(
    String query, {
    int limit = 10,
  }) async {
    final http.Response response = await _get(
      _appViewUri('app.bsky.actor.searchActors', <String, String>{
        'q': query,
        'limit': limit.toString(),
      }),
    );
    final Map<String, dynamic> json =
        _decode(response) as Map<String, dynamic>;
    final List<Object?> list =
        (json['actors'] as List<Object?>?) ?? const <Object?>[];
    return list
        .whereType<Map<String, dynamic>>()
        .map(BlueskyProfile.fromJson)
        .toList();
  }

  /// Searches public posts. AppView, works for guests.
  Future<List<BlueskyPost>> searchPosts(
    String query, {
    int limit = 10,
  }) async {
    final http.Response response = await _get(
      _appViewUri('app.bsky.feed.searchPosts', <String, String>{
        'q': query,
        'limit': limit.toString(),
      }),
    );
    final Map<String, dynamic> json =
        _decode(response) as Map<String, dynamic>;
    final List<Object?> list =
        (json['posts'] as List<Object?>?) ?? const <Object?>[];
    return list
        .whereType<Map<String, dynamic>>()
        .map(BlueskyPost.fromJson)
        .toList();
  }

  /// Posts text. [replyTo] turns it into a reply (root + parent).
  Future<BlueskyPostRef> createPost({
    required String text,
    BlueskyReplyRef? replyTo,
  }) async {
    final Map<String, Object?> record = <String, Object?>{
      r'$type': 'app.bsky.feed.post',
      'text': text,
      'createdAt': _nowIso(),
    };
    if (replyTo != null) {
      record['reply'] = <String, Object?>{
        'root': <String, String>{
          'uri': replyTo.rootUri,
          'cid': replyTo.rootCid,
        },
        'parent': <String, String>{
          'uri': replyTo.parentUri,
          'cid': replyTo.parentCid,
        },
      };
    }
    return createRecord(
      collection: 'app.bsky.feed.post',
      record: record,
    );
  }

  /// Likes a post. Returns the like record's URI (needed to unlike).
  Future<String> likePost({
    required String uri,
    required String cid,
  }) async {
    final BlueskyPostRef ref = await createRecord(
      collection: 'app.bsky.feed.like',
      record: <String, Object?>{
        r'$type': 'app.bsky.feed.like',
        'subject': <String, String>{'uri': uri, 'cid': cid},
        'createdAt': _nowIso(),
      },
    );
    return ref.uri;
  }

  /// Removes a like, given the like record's URI.
  Future<void> unlikePost(String likeUri) async {
    await deleteRecord(
      collection: 'app.bsky.feed.like',
      rkey: atUriRkey(likeUri),
    );
  }

  /// Reposts a post. Returns the repost record's URI.
  Future<String> repostPost({
    required String uri,
    required String cid,
  }) async {
    final BlueskyPostRef ref = await createRecord(
      collection: 'app.bsky.feed.repost',
      record: <String, Object?>{
        r'$type': 'app.bsky.feed.repost',
        'subject': <String, String>{'uri': uri, 'cid': cid},
        'createdAt': _nowIso(),
      },
    );
    return ref.uri;
  }

  /// Removes a repost, given the repost record's URI.
  Future<void> unrepostPost(String repostUri) async {
    await deleteRecord(
      collection: 'app.bsky.feed.repost',
      rkey: atUriRkey(repostUri),
    );
  }

  /// Follows an account (by DID). Returns the follow record's URI.
  Future<String> follow({required String subjectDid}) async {
    final BlueskyPostRef ref = await createRecord(
      collection: 'app.bsky.graph.follow',
      record: <String, Object?>{
        r'$type': 'app.bsky.graph.follow',
        'subject': subjectDid,
        'createdAt': _nowIso(),
      },
    );
    return ref.uri;
  }

  /// Unfollows an account, given the follow record's URI.
  Future<void> unfollow(String followUri) async {
    await deleteRecord(
      collection: 'app.bsky.graph.follow',
      rkey: atUriRkey(followUri),
    );
  }

  /// Creates a record in a collection on the PDS. Returns its
  /// URI/CID. All writes (post, like, repost, follow) go through
  /// here.
  Future<BlueskyPostRef> createRecord({
    required String collection,
    required Map<String, Object?> record,
  }) async {
    final String? repo = did;
    if (repo == null || repo.isEmpty) {
      throw const BlueskyApiException('No account DID: log in first.');
    }
    final http.Response response = await _post(
      _pdsUri('com.atproto.repo.createRecord'),
      jsonBody: <String, Object?>{
        'repo': repo,
        'collection': collection,
        'record': record,
      },
      authenticated: true,
    );
    return BlueskyPostRef.fromJson(
      _decode(response) as Map<String, dynamic>,
    );
  }

  /// Deletes a record by collection + rkey. Used for unlike /
  /// unrepost / unfollow.
  Future<void> deleteRecord({
    required String collection,
    required String rkey,
  }) async {
    final String? repo = did;
    if (repo == null || repo.isEmpty) {
      throw const BlueskyApiException('No account DID: log in first.');
    }
    await _post(
      _pdsUri('com.atproto.repo.deleteRecord'),
      jsonBody: <String, Object?>{
        'repo': repo,
        'collection': collection,
        'rkey': rkey,
      },
      authenticated: true,
    );
  }

  List<BlueskyFeedView> _decodeFeed(http.Response response) {
    final Map<String, dynamic> json =
        _decode(response) as Map<String, dynamic>;
    final List<Object?> list =
        (json['feed'] as List<Object?>?) ?? const <Object?>[];
    return list
        .whereType<Map<String, dynamic>>()
        .map(BlueskyFeedView.fromJson)
        .toList();
  }

  String _nowIso() => DateTime.now().toUtc().toIso8601String();

  Future<http.Response> _get(
    Uri uri, {
    bool authenticated = false,
  }) async {
    try {
      http.Response response = await _http.get(
        uri,
        headers: authenticated ? _authHeaders : null,
      );
      if (authenticated && _isExpiredToken(response)) {
        await refreshSession();
        response = await _http.get(uri, headers: _authHeaders);
      }
      return _check(response);
    } on http.ClientException catch (e) {
      throw BlueskyApiException(
        'Could not reach ${uri.host}: ${e.message}',
      );
    }
  }

  Future<http.Response> _post(
    Uri uri, {
    Map<String, Object?>? jsonBody,
    Map<String, String>? headers,
    bool authenticated = false,
  }) async {
    try {
      final Map<String, String> allHeaders = <String, String>{
        if (authenticated) ..._authHeaders,
        ...?headers,
        if (jsonBody != null) 'Content-Type': 'application/json',
      };
      http.Response response = await _http.post(
        uri,
        headers: allHeaders.isEmpty ? null : allHeaders,
        body: jsonBody == null ? null : jsonEncode(jsonBody),
      );
      if (authenticated && _isExpiredToken(response)) {
        await refreshSession();
        final Map<String, String> retryHeaders = <String, String>{
          ..._authHeaders,
          ...?headers,
          if (jsonBody != null) 'Content-Type': 'application/json',
        };
        response = await _http.post(
          uri,
          headers: retryHeaders.isEmpty ? null : retryHeaders,
          body: jsonBody == null ? null : jsonEncode(jsonBody),
        );
      }
      return _check(response);
    } on http.ClientException catch (e) {
      throw BlueskyApiException(
        'Could not reach ${uri.host}: ${e.message}',
      );
    }
  }

  /// True when the response is a 401 with an `ExpiredToken` error —
  /// the access JWT ran out and a refresh is worth trying.
  bool _isExpiredToken(http.Response response) {
    if (response.statusCode != 401) return false;
    try {
      final Object? json = jsonDecode(response.body);
      if (json is Map<String, dynamic>) {
        return (json['error'] as String?) == 'ExpiredToken';
      }
    } catch (_) {
      // Non-JSON 401: not a refreshable token expiry.
    }
    return false;
  }

  http.Response _check(http.Response response) {
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return response;
    }
    String detail = '';
    try {
      final Object? json = jsonDecode(response.body);
      if (json is Map<String, dynamic>) {
        detail = (json['message'] as String?) ??
            (json['error'] as String?) ??
            '';
      }
    } catch (_) {
      // Non-JSON error body: fall back to the status text.
    }
    if (detail.isEmpty) detail = response.reasonPhrase ?? 'Request failed';
    throw BlueskyApiException(
      detail,
      statusCode: response.statusCode,
    );
  }

  Object? _decode(http.Response response) {
    try {
      return jsonDecode(response.body);
    } on FormatException {
      throw BlueskyApiException(
        'Unexpected response from ${response.request?.url.host ?? 'Bluesky'}: not JSON.',
        statusCode: response.statusCode,
      );
    }
  }
}
