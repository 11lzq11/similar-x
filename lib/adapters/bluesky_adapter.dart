import '../core/account_store.dart';
import '../core/platform_adapter.dart';
import 'bluesky/bluesky_client.dart';
import 'bluesky/bluesky_models.dart';

/// Thrown when a Bluesky action needs a logged-in account.
class BlueskyNotLoggedInException implements Exception {
  @override
  String toString() =>
      'BlueskyNotLoggedInException: log in to Bluesky first.';
}

/// Bluesky — tier 1, fully feasible.
///
/// AT Protocol, fully open and free. Public content (profiles,
/// posts, followers) is readable without login via the public
/// AppView (https://public.api.bsky.app); writes use an App
/// Password, never the account password. No approval, no paid tier.
/// Reference clients: the official social-app (open source),
/// Graysky.
///
/// Login: the user enters their handle and an App Password
/// (Bluesky Settings > Privacy and security > App passwords).
/// The session (access + refresh JWT) is stored encrypted
/// on-device and only ever sent to Bluesky's own servers. The
/// access JWT expires after about two hours; the client refreshes
/// it automatically and the new tokens are persisted here.
///
/// Guests are not forced to log in: without an account the
/// timeline shows the Discover ("What's Hot") feed.
class BlueskyAdapter extends PlatformAdapter {
  BlueskyAdapter({BlueskyClient? client, AccountStore? accountStore}) {
    _client = client;
    _accountStore = accountStore ?? AccountStore();
  }

  static const String _serviceKey = 'bluesky_service';
  static const String _refreshKey = 'bluesky_refresh_jwt';
  static const String _handleKey = 'bluesky_handle';
  static const String _didKey = 'bluesky_did';

  late final AccountStore _accountStore;
  BlueskyClient? _client;

  @override
  String get id => 'bluesky';

  @override
  String get displayName => 'Bluesky';

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
      'AT Protocol — free, public reads need no login; '
      'writes use an App Password.';

  @override
  bool get requiresLogin => false;

  /// The PDS host this adapter talks to (stored, or the default).
  Future<String> get service async {
    try {
      final String? stored = await _accountStore.readValue(_serviceKey);
      if (stored != null && stored.isNotEmpty) return stored;
    } catch (_) {
      // Secure-storage errors fall back to the default service.
    }
    return blueskyDefaultService;
  }

  /// Points the adapter at another PDS. The host is normalized
  /// (`https://bsky.social/` -> `bsky.social`); an invalid host
  /// throws [BlueskyApiException]. Switching PDS forgets the login
  /// — a new PDS means a different account.
  Future<void> setService(String host) async {
    final String normalized = normalizeBlueskyService(host);
    final String current = await service;
    if (normalized == current) return;
    await _accountStore.saveValue(_serviceKey, normalized);
    await logout();
    final BlueskyClient? client = _client;
    if (client != null) client.service = normalized;
  }

  @override
  Future<bool> get isLoggedIn async {
    try {
      final String? token = await _accountStore.readToken(id);
      if (token == null || token.isEmpty) return false;
      final BlueskyClient client = await _ensureClient();
      client.accessJwt = token;
      return true;
    } catch (_) {
      return false;
    }
  }

  /// The unified timeline: the home timeline when logged in, the
  /// Discover ("What's Hot") feed for guests. Reposts show the
  /// original post.
  @override
  Future<List<Post>> fetchTimeline({int limit = 20}) async {
    final BlueskyClient client = await _ensureClient();
    final bool loggedIn = await isLoggedIn;
    final List<BlueskyFeedView> feed = loggedIn
        ? await client.homeTimeline(limit: limit)
        : await client.discoverFeed(limit: limit);
    return feed.map(_toPost).toList();
  }

  Post _toPost(BlueskyFeedView view) {
    final BlueskyPost post = view.post;
    return Post(
      id: 'bluesky:${post.uri}',
      platformId: id,
      authorName: post.author.name,
      authorHandle: post.author.handle,
      text: post.text,
      createdAt: post.createdAt,
      likeCount: post.likeCount,
      repostCount: post.repostCount,
      replyCount: post.replyCount,
    );
  }

  /// Starts the login flow. Bluesky login needs a handle and an
  /// App Password, so the UI collects them first and calls
  /// [loginWithAppPassword]; calling [login] directly throws.
  @override
  Future<void> login() async {
    throw const BlueskyApiException(
      'Bluesky login needs a handle and an App Password: '
      'use loginWithAppPassword.',
    );
  }

  /// Logs in with a handle (e.g. alice.bsky.social) and an App
  /// Password. Stores the session tokens and returns the
  /// logged-in profile. The account password must never be used.
  Future<BlueskyProfile> loginWithAppPassword({
    required String handle,
    required String appPassword,
  }) async {
    final String identifier = normalizeBlueskyHandle(handle);
    final BlueskyClient client = await _ensureClient();
    final BlueskySession session = await client.createSession(
      identifier: identifier,
      password: appPassword,
    );
    await _storeSession(session);
    return client.getProfile(session.handle);
  }

  /// The logged-in profile, or null when logged out.
  Future<BlueskyProfile?> get account async {
    if (!await isLoggedIn) return null;
    final BlueskyClient client = _client!;
    final String? handle = client.handle;
    if (handle == null || handle.isEmpty) return null;
    return client.getProfile(handle);
  }

  /// The home timeline (logged-in accounts only).
  Future<List<BlueskyFeedView>> fetchHomeTimeline({
    int limit = 20,
  }) async {
    final BlueskyClient client = await _requireLogin();
    return client.homeTimeline(limit: limit);
  }

  /// The Discover feed (works for guests too).
  Future<List<BlueskyFeedView>> fetchDiscoverFeed({
    int limit = 20,
  }) async {
    final BlueskyClient client = await _ensureClient();
    return client.discoverFeed(limit: limit);
  }

  /// Posts by one actor (handle or DID). Works for guests too.
  Future<List<BlueskyFeedView>> fetchAuthorFeed(
    String actor, {
    int limit = 20,
  }) async {
    final BlueskyClient client = await _ensureClient();
    return client.authorFeed(actor: actor, limit: limit);
  }

  /// A profile (handle or DID). Works for guests too.
  Future<BlueskyProfile> fetchProfile(String actor) async {
    final BlueskyClient client = await _ensureClient();
    return client.getProfile(actor);
  }

  /// Posts text. Returns the new post's URI + CID.
  Future<BlueskyPostRef> postText(String text) async {
    final BlueskyClient client = await _requireLogin();
    return client.createPost(text: text);
  }

  /// Replies to a post. [postUri]/[postCid] identify the post
  /// being replied to; [rootUri]/[rootCid] identify the thread
  /// root and default to the replied-to post (correct for a
  /// direct reply to a top-level post).
  Future<BlueskyPostRef> reply(
    String postUri,
    String postCid,
    String text, {
    String? rootUri,
    String? rootCid,
  }) async {
    final BlueskyClient client = await _requireLogin();
    return client.createPost(
      text: text,
      replyTo: BlueskyReplyRef(
        rootUri: rootUri ?? postUri,
        rootCid: rootCid ?? postCid,
        parentUri: postUri,
        parentCid: postCid,
      ),
    );
  }

  /// Likes a post. Returns the like record's URI (needed to
  /// unlike).
  Future<String> likePost(String uri, String cid) async {
    final BlueskyClient client = await _requireLogin();
    return client.likePost(uri: uri, cid: cid);
  }

  /// Removes a like, given the like record's URI.
  Future<void> unlikePost(String likeUri) async {
    final BlueskyClient client = await _requireLogin();
    await client.unlikePost(likeUri);
  }

  /// Reposts a post. Returns the repost record's URI.
  Future<String> repostPost(String uri, String cid) async {
    final BlueskyClient client = await _requireLogin();
    return client.repostPost(uri: uri, cid: cid);
  }

  /// Removes a repost, given the repost record's URI.
  Future<void> unrepostPost(String repostUri) async {
    final BlueskyClient client = await _requireLogin();
    await client.unrepostPost(repostUri);
  }

  /// A post thread: the post, its parent chain and replies.
  /// Works for guests too.
  Future<BlueskyThreadPost> fetchThread(
    String uri, {
    int depth = 6,
  }) async {
    final BlueskyClient client = await _ensureClient();
    return client.getThread(uri: uri, depth: depth);
  }

  /// Notifications: likes, reposts, follows, mentions, replies.
  Future<List<BlueskyNotification>> fetchNotifications({
    int limit = 20,
  }) async {
    final BlueskyClient client = await _requireLogin();
    return client.listNotifications(limit: limit);
  }

  /// Follows an account (by DID). Returns the follow record's URI.
  Future<String> followAccount(String did) async {
    final BlueskyClient client = await _requireLogin();
    return client.follow(subjectDid: did);
  }

  /// Unfollows an account, given the follow record's URI.
  Future<void> unfollowAccount(String followUri) async {
    final BlueskyClient client = await _requireLogin();
    await client.unfollow(followUri);
  }

  /// Searches accounts by name or handle. Works for guests too.
  Future<List<BlueskyProfile>> searchActors(
    String query, {
    int limit = 10,
  }) async {
    final BlueskyClient client = await _ensureClient();
    return client.searchActors(query, limit: limit);
  }

  /// Searches public posts. Works for guests too.
  Future<List<BlueskyPost>> searchPosts(
    String query, {
    int limit = 10,
  }) async {
    final BlueskyClient client = await _ensureClient();
    return client.searchPosts(query, limit: limit);
  }

  /// Logs out: the access token, refresh token, handle and DID
  /// are deleted. The PDS host is kept so the next login goes to
  /// the same service.
  @override
  Future<void> logout() async {
    await _accountStore.deleteToken(id);
    await _accountStore.deleteValue(_refreshKey);
    await _accountStore.deleteValue(_handleKey);
    await _accountStore.deleteValue(_didKey);
    final BlueskyClient? client = _client;
    if (client != null) {
      client.accessJwt = null;
      client.refreshJwt = null;
      client.did = null;
      client.handle = null;
    }
  }

  Future<void> _storeSession(BlueskySession session) async {
    await _accountStore.saveToken(id, session.accessJwt);
    await _accountStore.saveValue(_refreshKey, session.refreshJwt);
    await _accountStore.saveValue(_handleKey, session.handle);
    await _accountStore.saveValue(_didKey, session.did);
  }

  Future<BlueskyClient> _ensureClient() async {
    final BlueskyClient? existing = _client;
    if (existing != null) {
      existing.service = await service;
      existing.onSessionRefreshed = _storeSession;
      existing.accessJwt = await _readTokenQuiet();
      existing.refreshJwt = await _readValueQuiet(_refreshKey);
      existing.did = await _readValueQuiet(_didKey);
      existing.handle = await _readValueQuiet(_handleKey);
      return existing;
    }
    final BlueskyClient client = BlueskyClient(
      service: await service,
    );
    client.onSessionRefreshed = _storeSession;
    client.accessJwt = await _readTokenQuiet();
    client.refreshJwt = await _readValueQuiet(_refreshKey);
    client.did = await _readValueQuiet(_didKey);
    client.handle = await _readValueQuiet(_handleKey);
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

  Future<String?> _readValueQuiet(String key) async {
    try {
      return await _accountStore.readValue(key);
    } catch (_) {
      return null;
    }
  }

  Future<BlueskyClient> _requireLogin() async {
    if (!await isLoggedIn) throw BlueskyNotLoggedInException();
    return _client!;
  }
}
