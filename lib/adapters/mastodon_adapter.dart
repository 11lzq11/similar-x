import '../core/account_store.dart';
import '../core/platform_adapter.dart';
import 'mastodon/mastodon_client.dart';
import 'mastodon/mastodon_models.dart';

/// Thrown when a Mastodon action needs a logged-in account.
class MastodonNotLoggedInException implements Exception {
  @override
  String toString() =>
      'MastodonNotLoggedInException: log in to Mastodon first.';
}

/// Mastodon — tier 1, fully feasible.
///
/// Open federated network (ActivityPub). The REST API is fully
/// public: no app registration with Mastodon itself, no approval, no
/// quota. One integration covers Mastodon, Pleroma, GoToSocial and
/// Friendica — the user just enters their instance domain.
///
/// Login is standard OAuth with PKCE (S256): the app registers
/// itself on the instance, the user authorizes in the browser, and
/// pastes the authorization code back (out-of-band redirect — see
/// [mastodonOobRedirect]). The user never types their Mastodon
/// password into Similar-X. The access token is stored encrypted
/// on-device and only ever sent to the user's own instance.
///
/// Guests are not forced to log in: without an account the timeline
/// shows the instance's public timeline.
class MastodonAdapter extends PlatformAdapter {
  MastodonAdapter({MastodonClient? client, AccountStore? accountStore}) {
    _client = client;
    _accountStore = accountStore ?? AccountStore();
  }

  /// The instance used when the user has not picked one yet.
  static const String defaultInstance = 'mastodon.social';

  static const String _instanceKey = 'mastodon_instance';
  static const String _clientIdKey = 'mastodon_client_id';
  static const String _clientSecretKey = 'mastodon_client_secret';
  static const String _verifierKey = 'mastodon_code_verifier';

  late final AccountStore _accountStore;
  MastodonClient? _client;

  /// The authorize URL from the last [beginLogin] call, for the UI
  /// to open in a browser. Null before login starts.
  Uri? authorizeUrl;

  @override
  String get id => 'mastodon';

  @override
  String get displayName => 'Mastodon';

  @override
  PlatformStatus get status => PlatformStatus.ready;

  @override
  Set<AdapterCapability> get capabilities => const <AdapterCapability>{
        AdapterCapability.timeline,
        AdapterCapability.post,
        AdapterCapability.like,
        AdapterCapability.comment,
        AdapterCapability.repost,
        AdapterCapability.notifications,
        AdapterCapability.search,
      };

  @override
  String get note =>
      'Open API — any instance works, no approval, no quota.';

  @override
  bool get requiresLogin => false;

  /// The instance this adapter talks to (stored, or the default).
  Future<String> get instance async {
    try {
      final String? stored = await _accountStore.readValue(_instanceKey);
      if (stored != null && stored.isNotEmpty) return stored;
    } catch (_) {
      // Secure-storage errors fall back to the default instance.
    }
    return defaultInstance;
  }

  /// Points the adapter at another instance. The domain is
  /// normalized (`https://mastodon.social/` -> `mastodon.social`);
  /// an invalid domain throws [MastodonApiException]. Switching
  /// instances forgets the login and the app credentials — a new
  /// instance means a different account.
  Future<void> setInstance(String domain) async {
    final String normalized = normalizeInstance(domain);
    final String current = await instance;
    if (normalized == current) return;
    await _accountStore.saveValue(_instanceKey, normalized);
    await _accountStore.deleteToken(id);
    await _accountStore.deleteValue(_clientIdKey);
    await _accountStore.deleteValue(_clientSecretKey);
    await _accountStore.deleteValue(_verifierKey);
    authorizeUrl = null;
    final MastodonClient? client = _client;
    if (client != null) {
      client.instance = normalized;
      client.accessToken = null;
    }
  }

  @override
  Future<bool> get isLoggedIn async {
    try {
      final String? token = await _accountStore.readToken(id);
      if (token == null || token.isEmpty) return false;
      final MastodonClient client = await _ensureClient();
      client.accessToken = token;
      return true;
    } catch (_) {
      return false;
    }
  }

  /// The unified timeline: the home timeline when logged in, the
  /// instance's public timeline for guests. Boosts show the original
  /// status.
  @override
  Future<List<Post>> fetchTimeline({int limit = 20}) async {
    final MastodonClient client = await _ensureClient();
    final bool loggedIn = await isLoggedIn;
    final List<MastodonStatus> statuses = loggedIn
        ? await client.homeTimeline(limit: limit)
        : await client.publicTimeline(limit: limit);
    return statuses.map(_toPost).toList();
  }

  Post _toPost(MastodonStatus status) {
    final MastodonStatus shown = status.displayStatus;
    return Post(
      id: 'mastodon:${status.id}',
      platformId: id,
      authorName: shown.account.name,
      authorHandle: shown.account.acct,
      text: shown.content,
      createdAt: shown.createdAt,
      likeCount: shown.favouritesCount,
      repostCount: shown.reblogCount,
      replyCount: shown.repliesCount,
    );
  }

  /// Starts the login flow: registers Similar-X on the instance
  /// (first time only), generates the PKCE verifier, and builds the
  /// authorize URL. The UI opens [authorizeUrl] in a browser; the
  /// user authorizes there and pastes the code into
  /// [submitAuthorizationCode].
  @override
  Future<void> login() async {
    await beginLogin();
  }

  /// The login flow, returning the authorize URL directly.
  /// [instance] switches instances first when given.
  Future<Uri> beginLogin({String? instance}) async {
    if (instance != null) await setInstance(instance);
    final MastodonClient client = await _ensureClient();
    final MastodonAppCredentials app = await _ensureApp(client);
    final String verifier = generateCodeVerifier();
    await _accountStore.saveValue(_verifierKey, verifier);
    final Uri url = client.buildAuthorizeUrl(
      clientId: app.clientId,
      codeChallenge: codeChallengeS256(verifier),
    );
    authorizeUrl = url;
    return url;
  }

  /// Completes login with the authorization code from the browser.
  /// Stores the access token and returns the logged-in account.
  Future<MastodonAccount> submitAuthorizationCode(String code) async {
    final MastodonClient client = await _ensureClient();
    final MastodonAppCredentials app = await _ensureApp(client);
    final String? verifier = await _accountStore.readValue(_verifierKey);
    if (verifier == null || verifier.isEmpty) {
      throw const MastodonApiException(
        'Login expired: start the login flow again.',
      );
    }
    final String token = await client.exchangeCode(
      code: code.trim(),
      clientId: app.clientId,
      clientSecret: app.clientSecret,
      codeVerifier: verifier,
    );
    await _accountStore.saveToken(id, token);
    await _accountStore.deleteValue(_verifierKey);
    client.accessToken = token;
    authorizeUrl = null;
    return client.verifyCredentials();
  }

  /// The logged-in account, or null when logged out.
  Future<MastodonAccount?> get account async {
    if (!await isLoggedIn) return null;
    return _client!.verifyCredentials();
  }

  /// The home timeline (logged-in accounts only).
  Future<List<MastodonStatus>> fetchHomeTimeline({
    int limit = 20,
  }) async {
    final MastodonClient client = await _requireLogin();
    return client.homeTimeline(limit: limit);
  }

  /// The instance's public timeline (works for guests too).
  Future<List<MastodonStatus>> fetchPublicTimeline({
    int limit = 20,
  }) async {
    final MastodonClient client = await _ensureClient();
    return client.publicTimeline(limit: limit);
  }

  /// Posts a status ("toot").
  Future<MastodonStatus> postStatus(
    String text, {
    String visibility = 'public',
  }) async {
    final MastodonClient client = await _requireLogin();
    return client.postStatus(status: text, visibility: visibility);
  }

  /// Replies to a status.
  Future<MastodonStatus> reply(String statusId, String text) async {
    final MastodonClient client = await _requireLogin();
    return client.postStatus(status: text, inReplyToId: statusId);
  }

  /// Favourites (likes) a status.
  Future<MastodonStatus> favourite(String statusId) async {
    final MastodonClient client = await _requireLogin();
    return client.favourite(statusId);
  }

  /// Removes a favourite.
  Future<MastodonStatus> unfavourite(String statusId) async {
    final MastodonClient client = await _requireLogin();
    return client.unfavourite(statusId);
  }

  /// Boosts (reposts) a status.
  Future<MastodonStatus> reblog(String statusId) async {
    final MastodonClient client = await _requireLogin();
    return client.reblog(statusId);
  }

  /// Removes a boost.
  Future<MastodonStatus> unreblog(String statusId) async {
    final MastodonClient client = await _requireLogin();
    return client.unreblog(statusId);
  }

  /// Notifications: mentions, favourites, boosts, follows, ...
  Future<List<MastodonNotification>> fetchNotifications({
    int limit = 20,
  }) async {
    final MastodonClient client = await _requireLogin();
    return client.notifications(limit: limit);
  }

  /// Follows an account.
  Future<MastodonRelationship> followAccount(String accountId) async {
    final MastodonClient client = await _requireLogin();
    return client.followAccount(accountId);
  }

  /// Unfollows an account.
  Future<MastodonRelationship> unfollowAccount(
    String accountId,
  ) async {
    final MastodonClient client = await _requireLogin();
    return client.unfollowAccount(accountId);
  }

  /// Searches accounts by name or handle.
  Future<List<MastodonAccount>> searchAccounts(
    String query, {
    int limit = 10,
  }) async {
    final MastodonClient client = await _ensureClient();
    final MastodonSearchResult result = await client.search(
      query,
      type: 'accounts',
      limit: limit,
    );
    return result.accounts;
  }

  /// Searches public statuses.
  Future<List<MastodonStatus>> searchStatuses(
    String query, {
    int limit = 10,
  }) async {
    final MastodonClient client = await _ensureClient();
    final MastodonSearchResult result = await client.search(
      query,
      type: 'statuses',
      limit: limit,
    );
    return result.statuses;
  }

  /// Logs out: the access token and the pending PKCE verifier are
  /// deleted. The instance and the app credentials are kept so the
  /// next login skips registration.
  @override
  Future<void> logout() async {
    await _accountStore.deleteToken(id);
    await _accountStore.deleteValue(_verifierKey);
    authorizeUrl = null;
    _client?.accessToken = null;
  }

  Future<MastodonClient> _ensureClient() async {
    final MastodonClient? existing = _client;
    if (existing != null) {
      existing.instance = await instance;
      final String? token = await _readTokenQuiet();
      existing.accessToken = token;
      return existing;
    }
    final MastodonClient client = MastodonClient(
      instance: await instance,
    );
    client.accessToken = await _readTokenQuiet();
    _client = client;
    return client;
  }

  Future<String?> _readTokenQuiet() async {
    try {
      return await _accountStore.readToken(id);
    } catch (_) {
      return null;
    }
  }

  /// The OAuth app credentials for this instance, registering the
  /// app on first use and reusing the stored ones afterwards.
  Future<MastodonAppCredentials> _ensureApp(
    MastodonClient client,
  ) async {
    final String? clientId =
        await _accountStore.readValue(_clientIdKey);
    final String? clientSecret =
        await _accountStore.readValue(_clientSecretKey);
    if (clientId != null &&
        clientId.isNotEmpty &&
        clientSecret != null &&
        clientSecret.isNotEmpty) {
      return MastodonAppCredentials(
        clientId: clientId,
        clientSecret: clientSecret,
      );
    }
    final MastodonAppCredentials app = await client.registerApp();
    if (!app.isValid) {
      throw const MastodonApiException(
        'Instance did not return OAuth app credentials.',
      );
    }
    await _accountStore.saveValue(_clientIdKey, app.clientId);
    await _accountStore.saveValue(_clientSecretKey, app.clientSecret);
    return app;
  }

  Future<MastodonClient> _requireLogin() async {
    if (!await isLoggedIn) throw MastodonNotLoggedInException();
    return _client!;
  }
}
