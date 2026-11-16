/// Mastodon REST client: plain HTTPS + JSON over `package:http`.
///
/// Covers any Mastodon-compatible instance (Mastodon, Pleroma,
/// GoToSocial, Friendica): the same API shape is used everywhere.
/// No app registration with Mastodon itself is needed — the app
/// registers itself on the user's instance at login time
/// (`POST /api/v1/apps`), then runs the standard OAuth authorization
/// code flow with PKCE (S256, supported since Mastodon 4.3.0).
///
/// Login uses the out-of-band redirect (`urn:ietf:wg:oauth:2.0:oob`),
/// which Mastodon still documents: the instance shows the
/// authorization code on the approval page and the user pastes it
/// into Similar-X. A custom-scheme deep link can replace it later
/// without changing the API calls. The user never types their
/// Mastodon password into Similar-X.
library;

import 'dart:convert';
import 'dart:math' show Random;

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'mastodon_models.dart';

/// Thrown when a Mastodon API call fails: bad instance, network
/// error, or a non-2xx response. [statusCode] is the HTTP status
/// when the server answered, null when the request never reached it.
class MastodonApiException implements Exception {
  const MastodonApiException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() =>
      'MastodonApiException: $message'
      '${statusCode == null ? '' : ' (HTTP $statusCode)'}';
}

/// The OAuth application credentials returned by `POST /api/v1/apps`.
/// They identify Similar-X on one instance and are stored encrypted
/// on-device (see [MastodonAdapter]); they are not user credentials.
class MastodonAppCredentials {
  const MastodonAppCredentials({
    required this.clientId,
    required this.clientSecret,
  });

  factory MastodonAppCredentials.fromJson(Map<String, dynamic> json) =>
      MastodonAppCredentials(
        clientId: (json['client_id'] as String?) ?? '',
        clientSecret: (json['client_secret'] as String?) ?? '',
      );

  final String clientId;
  final String clientSecret;

  bool get isValid => clientId.isNotEmpty && clientSecret.isNotEmpty;
}

/// Normalizes a user-typed instance into a bare domain:
/// `https://mastodon.social/` -> `mastodon.social`.
/// Throws [MastodonApiException] for anything that is not a plausible
/// domain (empty, contains spaces or a path, ...).
String normalizeInstance(String input) {
  String domain = input.trim().toLowerCase();
  domain = domain.replaceFirst(RegExp(r'^https?://'), '');
  domain = domain.replaceAll(RegExp(r'/.*$'), '');
  domain = domain.replaceAll(RegExp(r':\d+$'), '');
  if (domain.isEmpty ||
      domain.contains(RegExp(r'\s')) ||
      !domain.contains('.') ||
      !RegExp(r'^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$').hasMatch(domain)) {
    throw MastodonApiException(
      'Not a valid instance domain: "$input". '
      'Enter just the domain, e.g. mastodon.social',
    );
  }
  return domain;
}

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

/// The out-of-band redirect: Mastodon shows the authorization code
/// on the approval page instead of redirecting anywhere.
const String mastodonOobRedirect = 'urn:ietf:wg:oauth:2.0:oob';

/// Scopes Similar-X asks for: read timelines and notifications,
/// write posts, follow accounts. The smallest set that covers the
/// adapter's capabilities.
const List<String> mastodonScopes = <String>['read', 'write', 'follow'];

/// One Mastodon instance, one REST client.
///
/// The client holds no token by itself: [accessToken] is set by the
/// adapter after login and cleared on logout. Calls without a token
/// work for public endpoints (public timeline, search) — guest mode.
class MastodonClient {
  MastodonClient({required String instance, http.Client? httpClient})
      : instance = normalizeInstance(instance),
        _http = httpClient ?? http.Client();

  /// The instance domain this client talks to. Settable so the
  /// adapter can point an injected (test) client at a new instance.
  String instance;

  String? accessToken;

  final http.Client _http;

  Uri _uri(String path, [Map<String, String>? query]) => Uri.https(
        instance,
        path,
        query == null || query.isEmpty ? null : query,
      );

  Map<String, String> get _authHeaders {
    final String? token = accessToken;
    if (token == null || token.isEmpty) return const <String, String>{};
    return <String, String>{'Authorization': 'Bearer $token'};
  }

  /// Registers Similar-X as an OAuth application on this instance.
  /// No user interaction, no approval — any instance accepts it.
  Future<MastodonAppCredentials> registerApp() async {
    final http.Response response = await _post(
      _uri('/api/v1/apps'),
      body: <String, String>{
        'client_name': 'Similar-X',
        'redirect_uris': mastodonOobRedirect,
        'scopes': mastodonScopes.join(' '),
        'website': 'https://github.com/11lzq11/similar-x',
      },
    );
    return MastodonAppCredentials.fromJson(
      _decode(response) as Map<String, dynamic>,
    );
  }

  /// The URL the user opens in a browser to authorize Similar-X.
  /// [codeChallenge] is the PKCE S256 challenge for the verifier the
  /// adapter stored; the instance shows the authorization code after
  /// approval and the user pastes it back into the app.
  Uri buildAuthorizeUrl({
    required String clientId,
    required String codeChallenge,
  }) =>
      _uri('/oauth/authorize', <String, String>{
        'response_type': 'code',
        'client_id': clientId,
        'redirect_uri': mastodonOobRedirect,
        'scope': mastodonScopes.join(' '),
        'code_challenge': codeChallenge,
        'code_challenge_method': 'S256',
      });

  /// Exchanges the authorization code for an access token.
  Future<String> exchangeCode({
    required String code,
    required String clientId,
    required String clientSecret,
    required String codeVerifier,
  }) async {
    final http.Response response = await _post(
      _uri('/oauth/token'),
      body: <String, String>{
        'grant_type': 'authorization_code',
        'code': code,
        'client_id': clientId,
        'client_secret': clientSecret,
        'redirect_uri': mastodonOobRedirect,
        'scope': mastodonScopes.join(' '),
        'code_verifier': codeVerifier,
      },
    );
    final Map<String, dynamic> json =
        _decode(response) as Map<String, dynamic>;
    final String? token = json['access_token'] as String?;
    if (token == null || token.isEmpty) {
      throw const MastodonApiException(
        'Token exchange failed: no access token returned.',
      );
    }
    return token;
  }

  /// The logged-in account, or throws when the token is invalid.
  Future<MastodonAccount> verifyCredentials() async {
    final http.Response response = await _get(
      _uri('/api/v1/accounts/verify_credentials'),
      authenticated: true,
    );
    return MastodonAccount.fromJson(
      _decode(response) as Map<String, dynamic>,
    );
  }

  /// The home timeline: posts from accounts the user follows.
  Future<List<MastodonStatus>> homeTimeline({int limit = 20}) async {
    final http.Response response = await _get(
      _uri('/api/v1/timelines/home', <String, String>{
        'limit': limit.toString(),
      }),
      authenticated: true,
    );
    return _decodeStatusList(response);
  }

  /// The public timeline: public posts across the instance (and, by
  /// default, the wider fediverse). Works without login — guest mode.
  Future<List<MastodonStatus>> publicTimeline({
    int limit = 20,
    bool local = false,
  }) async {
    final http.Response response = await _get(
      _uri('/api/v1/timelines/public', <String, String>{
        'limit': limit.toString(),
        'local': local.toString(),
      }),
    );
    return _decodeStatusList(response);
  }

  /// Posts a status ("toot"). [inReplyToId] turns it into a reply.
  Future<MastodonStatus> postStatus({
    required String status,
    String? inReplyToId,
    String visibility = 'public',
  }) async {
    final Map<String, String> body = <String, String>{
      'status': status,
      'visibility': visibility,
    };
    if (inReplyToId != null) body['in_reply_to_id'] = inReplyToId;
    final http.Response response = await _post(
      _uri('/api/v1/statuses'),
      body: body,
      authenticated: true,
    );
    return MastodonStatus.fromJson(
      _decode(response) as Map<String, dynamic>,
    );
  }

  /// The context of a status: its ancestors and descendants
  /// (replies). Returns the descendants (replies) in thread order.
  /// The endpoint is public, so it works for guests too.
  Future<List<MastodonStatus>> statusContext(String statusId) async {
    final http.Response response = await _get(
      _uri('/api/v1/statuses/$statusId/context'),
    );
    final Map<String, dynamic> json =
        _decode(response) as Map<String, dynamic>;
    final List<Object?> descendants =
        (json['descendants'] as List<Object?>?) ?? const <Object?>[];
    return descendants
        .whereType<Map<String, dynamic>>()
        .map(MastodonStatus.fromJson)
        .toList();
  }

  /// Favourites (likes) a status.
  Future<MastodonStatus> favourite(String statusId) async {
    final http.Response response = await _post(
      _uri('/api/v1/statuses/$statusId/favourite'),
      authenticated: true,
    );
    return MastodonStatus.fromJson(
      _decode(response) as Map<String, dynamic>,
    );
  }

  /// Removes a favourite.
  Future<MastodonStatus> unfavourite(String statusId) async {
    final http.Response response = await _post(
      _uri('/api/v1/statuses/$statusId/unfavourite'),
      authenticated: true,
    );
    return MastodonStatus.fromJson(
      _decode(response) as Map<String, dynamic>,
    );
  }

  /// Boosts (reposts) a status.
  Future<MastodonStatus> reblog(String statusId) async {
    final http.Response response = await _post(
      _uri('/api/v1/statuses/$statusId/reblog'),
      authenticated: true,
    );
    return MastodonStatus.fromJson(
      _decode(response) as Map<String, dynamic>,
    );
  }

  /// Removes a boost.
  Future<MastodonStatus> unreblog(String statusId) async {
    final http.Response response = await _post(
      _uri('/api/v1/statuses/$statusId/unreblog'),
      authenticated: true,
    );
    return MastodonStatus.fromJson(
      _decode(response) as Map<String, dynamic>,
    );
  }

  /// Notifications: mentions, favourites, boosts, follows, ...
  Future<List<MastodonNotification>> notifications({
    int limit = 20,
  }) async {
    final http.Response response = await _get(
      _uri('/api/v1/notifications', <String, String>{
        'limit': limit.toString(),
      }),
      authenticated: true,
    );
    final List<Object?> list = _decode(response) as List<Object?>;
    return list
        .whereType<Map<String, dynamic>>()
        .map(MastodonNotification.fromJson)
        .toList();
  }

  /// Follows an account.
  Future<MastodonRelationship> followAccount(String accountId) async {
    final http.Response response = await _post(
      _uri('/api/v1/accounts/$accountId/follow'),
      authenticated: true,
    );
    return MastodonRelationship.fromJson(
      _decode(response) as Map<String, dynamic>,
    );
  }

  /// Unfollows an account.
  Future<MastodonRelationship> unfollowAccount(
    String accountId,
  ) async {
    final http.Response response = await _post(
      _uri('/api/v1/accounts/$accountId/unfollow'),
      authenticated: true,
    );
    return MastodonRelationship.fromJson(
      _decode(response) as Map<String, dynamic>,
    );
  }

  /// Searches accounts and statuses. [type] is `accounts`,
  /// `statuses` or `hashtags`; the result carries the matching
  /// lists (only the requested type is filled).
  Future<MastodonSearchResult> search(
    String query, {
    String type = 'accounts',
    int limit = 10,
  }) async {
    final http.Response response = await _get(
      _uri('/api/v2/search', <String, String>{
        'q': query,
        'type': type,
        'limit': limit.toString(),
      }),
      authenticated: accessToken != null && accessToken!.isNotEmpty,
    );
    return MastodonSearchResult.fromJson(
      _decode(response) as Map<String, dynamic>,
    );
  }

  List<MastodonStatus> _decodeStatusList(http.Response response) {
    final List<Object?> list = _decode(response) as List<Object?>;
    return list
        .whereType<Map<String, dynamic>>()
        .map(MastodonStatus.fromJson)
        .toList();
  }

  Future<http.Response> _get(
    Uri uri, {
    bool authenticated = false,
  }) async {
    try {
      final http.Response response = await _http.get(
        uri,
        headers: authenticated ? _authHeaders : null,
      );
      return _check(response);
    } on http.ClientException catch (e) {
      throw MastodonApiException(
        'Could not reach $instance: ${e.message}',
      );
    }
  }

  Future<http.Response> _post(
    Uri uri, {
    Map<String, String>? body,
    bool authenticated = false,
  }) async {
    try {
      final http.Response response = await _http.post(
        uri,
        headers: authenticated ? _authHeaders : null,
        body: body,
      );
      return _check(response);
    } on http.ClientException catch (e) {
      throw MastodonApiException(
        'Could not reach $instance: ${e.message}',
      );
    }
  }

  http.Response _check(http.Response response) {
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return response;
    }
    String detail = '';
    try {
      final Object? json = jsonDecode(response.body);
      if (json is Map<String, dynamic>) {
        detail = (json['error'] as String?) ?? '';
      }
    } catch (_) {
      // Non-JSON error body: fall back to the status text.
    }
    if (detail.isEmpty) detail = response.reasonPhrase ?? 'Request failed';
    throw MastodonApiException(
      detail,
      statusCode: response.statusCode,
    );
  }

  Object? _decode(http.Response response) {
    try {
      return jsonDecode(response.body);
    } on FormatException {
      throw MastodonApiException(
        'Unexpected response from $instance: not JSON.',
        statusCode: response.statusCode,
      );
    }
  }
}
