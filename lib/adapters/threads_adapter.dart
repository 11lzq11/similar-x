import 'dart:math';

import '../core/account_store.dart';
import '../core/platform_adapter.dart';
import 'threads/threads_client.dart';
import 'threads/threads_models.dart';

/// Thrown when a Threads action needs a logged-in account.
class ThreadsNotLoggedInException implements Exception {
  @override
  String toString() =>
      'ThreadsNotLoggedInException: log in to Threads first.';
}

/// Threads — tier 2, limited.
///
/// Official Threads API (graph.threads.net, v1.0), free, but
/// it can only read and write the user's OWN account: own
/// threads, replies to them, mentions, keyword search and
/// insights. There is **no public timeline, no home feed and
/// no way to read other people's content** — Meta's own docs
/// say apps may display posts solely to the person who
/// created them. Guest mode does not exist for Threads:
/// [requiresLogin] is true and the guest timeline is empty
/// (never fake data).
///
/// Auth is per-user, from the user's own Meta app — Similar-X
/// ships no shared app ID:
/// * **Threads App ID + App Secret** (developers.facebook.com
///   > create app > use case **Access the Threads API**; the
///   App ID is the Threads one, not the parent Meta App ID;
///   the secret is under App settings > Basic). Both are
///   stored encrypted on-device.
/// * **OAuth 2.0** (loopback redirect + manual-code fallback):
///   login exchanges the code for a short-lived token (1
///   hour), then immediately for a long-lived token (60 days).
///   The long-lived token is refreshed automatically on a 401
///   and proactively when it is close to expiry; a fully
///   expired or revoked token means logging in again.
/// * **Production use needs Meta App Review** for the Threads
///   use case. Before review, only the app's testers can log
///   in, and keyword search / mentions only cover the app's
///   own testers.
///
/// Limits: 250 posts / 1,000 replies / 100 deletions per
/// account per 24 hours; keyword search 500 requests per
/// rolling 7 days; text posts at most 500 characters.
///
/// **Liking is not supported**: the official Threads API has
/// no like endpoint (like/unlike in some third-party
/// libraries uses Threads' internal unofficial API). Like
/// counts are readable through insights, but there is no like
/// action — so the adapter does not declare the `like`
/// capability. Reference: developers.facebook.com/docs/threads.
class ThreadsAdapter extends PlatformAdapter {
  ThreadsAdapter({ThreadsClient? client, AccountStore? accountStore}) {
    _client = client;
    _accountStore = accountStore ?? AccountStore();
  }

  static const String _appIdKey = 'threads_app_id';
  static const String _appSecretKey = 'threads_app_secret';
  static const String _userIdKey = 'threads_user_id';
  static const String _expiresAtKey = 'threads_token_expires_at';

  late final AccountStore _accountStore;
  ThreadsClient? _client;

  /// The authorize URL from the last [beginOAuthLogin] call, for
  /// the UI to open in a browser. Null before login starts.
  Uri? authorizeUrl;

  ThreadsLoopbackAuthListener? _pendingListener;
  String? _pendingRedirectUri;
  String? _pendingAppId;
  String? _pendingAppSecret;
  String? _pendingState;

  @override
  String get id => 'threads';

  @override
  String get displayName => 'Threads';

  @override
  PlatformStatus get status => PlatformStatus.limited;

  @override
  Set<AdapterCapability> get capabilities => const <AdapterCapability>{
        AdapterCapability.timeline,
        AdapterCapability.post,
        AdapterCapability.comment,
        AdapterCapability.repost,
        AdapterCapability.search,
        AdapterCapability.notifications,
      };

  @override
  String get note =>
      'Limited — own account only, no public timeline; Meta '
      'App Review required for production; keyword search '
      '500/7 days; the official API has no like endpoint. '
      'Login is required — there is no guest mode.';

  @override
  bool get requiresLogin => true;

  /// The stored Threads App ID, or null when the user has
  /// not set one.
  Future<String?> get appId async {
    try {
      return await _accountStore.readValue(_appIdKey);
    } catch (_) {
      return null;
    }
  }

  /// The stored Threads App Secret, or null when the user has
  /// not set one.
  Future<String?> get appSecret async {
    try {
      return await _accountStore.readValue(_appSecretKey);
    } catch (_) {
      return null;
    }
  }

  /// Saves the user's Meta app credentials (Threads App ID +
  /// Threads App Secret). The secret is stored encrypted
  /// on-device and only ever sent to graph.threads.net.
  Future<void> setAppCredentials({
    required String appId,
    required String appSecret,
  }) async {
    final String id = appId.trim();
    final String secret = appSecret.trim();
    if (id.isEmpty) {
      throw const ThreadsApiException('Threads App ID must not be empty.');
    }
    if (secret.isEmpty) {
      throw const ThreadsApiException(
        'Threads App Secret must not be empty.',
      );
    }
    await _accountStore.saveValue(_appIdKey, id);
    await _accountStore.saveValue(_appSecretKey, secret);
    final ThreadsClient? client = _client;
    if (client != null) {
      client.appId = id;
      client.appSecret = secret;
    }
  }

  @override
  Future<bool> get isLoggedIn async {
    try {
      final String? token = await _accountStore.readToken(id);
      if (token == null || token.isEmpty) return false;
      await _ensureClient();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// The unified timeline: the account's own threads, newest
  /// first. Guests get an empty list — the official API
  /// exposes nothing without login, and Similar-X never shows
  /// fake data.
  @override
  Future<List<Post>> fetchTimeline({int limit = 20}) async {
    if (!await isLoggedIn) return const <Post>[];
    final ThreadsClient client = await _requireLogin();
    final List<ThreadsPost> posts =
        await client.listMyThreads(limit: limit);
    return posts.map(_toPost).toList();
  }

  Post _toPost(ThreadsPost post) => Post(
        id: 'threads:${post.id}',
        platformId: id,
        authorName: post.username,
        authorHandle: '@${post.username}',
        text: post.text,
        createdAt: post.timestamp,
        likeCount: post.likeCount,
        repostCount: post.repostCount,
        replyCount: post.replyCount,
      );

  /// The account's own threads, newest first.
  Future<List<ThreadsPost>> fetchMyThreads({int limit = 25}) async {
    final ThreadsClient client = await _requireLogin();
    return client.listMyThreads(limit: limit);
  }

  /// One post by media id.
  Future<ThreadsPost> fetchThread(String mediaId) async {
    final ThreadsClient client = await _requireLogin();
    return client.getThread(mediaId);
  }

  /// Top-level replies to a post.
  Future<List<ThreadsPost>> fetchReplies(
    String mediaId, {
    int limit = 25,
    bool reverse = true,
  }) async {
    final ThreadsClient client = await _requireLogin();
    return client.listReplies(
      mediaId,
      limit: limit,
      reverse: reverse,
    );
  }

  /// The full conversation tree under a post.
  Future<List<ThreadsPost>> fetchConversation(
    String mediaId, {
    int limit = 25,
  }) async {
    final ThreadsClient client = await _requireLogin();
    return client.listConversation(mediaId, limit: limit);
  }

  /// Posts that mention the account — the notifications
  /// feed. Needs the `threads_manage_mentions` scope.
  Future<List<ThreadsPost>> fetchMentions({int limit = 25}) async {
    final ThreadsClient client = await _requireLogin();
    return client.listMentions(limit: limit);
  }

  /// Searches posts by keyword or topic tag. 500 requests per
  /// rolling 7 days; before App Review it only searches the
  /// account's own posts. [searchType] is `TOP` or `RECENT`.
  Future<List<ThreadsPost>> searchKeyword(
    String query, {
    String searchType = 'TOP',
    int limit = 25,
  }) async {
    final ThreadsClient client = await _requireLogin();
    return client.searchKeyword(
      query,
      searchType: searchType,
      limit: limit,
    );
  }

  /// Posts a text thread. Returns the published post's media
  /// id. At most 500 characters.
  Future<String> postText(
    String text, {
    String? replyToId,
    String? quotePostId,
    String? topicTag,
  }) async {
    final ThreadsClient client = await _requireLogin();
    return client.postText(
      text,
      replyToId: replyToId,
      quotePostId: quotePostId,
      topicTag: topicTag,
    );
  }

  /// Posts a single-image thread. [imageUrl] must be publicly
  /// reachable — Threads fetches the image from the URL.
  Future<String> postImage(
    String text, {
    required String imageUrl,
    String? altText,
    String? replyToId,
    String? quotePostId,
    String? topicTag,
  }) async {
    final ThreadsClient client = await _requireLogin();
    return client.postImage(
      text,
      imageUrl: imageUrl,
      altText: altText,
      replyToId: replyToId,
      quotePostId: quotePostId,
      topicTag: topicTag,
    );
  }

  /// Posts a single-video thread (waits for the video to
  /// finish processing, then publishes).
  Future<String> postVideo(
    String text, {
    required String videoUrl,
    String? altText,
    String? replyToId,
    String? quotePostId,
    String? topicTag,
  }) async {
    final ThreadsClient client = await _requireLogin();
    return client.postVideo(
      text,
      videoUrl: videoUrl,
      altText: altText,
      replyToId: replyToId,
      quotePostId: quotePostId,
      topicTag: topicTag,
    );
  }

  /// Posts a carousel (2-20 images). Each item is
  /// `{'image_url': ..., 'alt_text': ...}`.
  Future<String> postCarousel(
    String text, {
    required List<Map<String, String>> items,
    String? replyToId,
    String? quotePostId,
    String? topicTag,
  }) async {
    final ThreadsClient client = await _requireLogin();
    final String creationId = await client.createCarouselContainer(
      text: text,
      items: items,
      replyToId: replyToId,
      quotePostId: quotePostId,
      topicTag: topicTag,
    );
    return client.publishContainer(creationId);
  }

  /// Replies to a post. [replyToId] must be the **root**
  /// post's id — every reply in a thread targets the root.
  Future<String> replyToThread({
    required String replyToId,
    required String text,
  }) async {
    final ThreadsClient client = await _requireLogin();
    return client.postText(text, replyToId: replyToId);
  }

  /// Quotes a post with the account's own text.
  Future<String> quoteThread({
    required String quotePostId,
    required String text,
  }) async {
    final ThreadsClient client = await _requireLogin();
    return client.postText(text, quotePostId: quotePostId);
  }

  /// Reposts a post. Returns the repost's id.
  Future<String> repostThread(String mediaId) async {
    final ThreadsClient client = await _requireLogin();
    return client.repost(mediaId);
  }

  /// Hides a reply to one of the account's posts.
  Future<void> hideReply(String mediaId) async {
    final ThreadsClient client = await _requireLogin();
    await client.hideReply(mediaId);
  }

  /// Unhides a reply hidden with [hideReply].
  Future<void> unhideReply(String mediaId) async {
    final ThreadsClient client = await _requireLogin();
    await client.unhideReply(mediaId);
  }

  /// Deletes one of the account's posts (100 per 24 hours).
  Future<void> deleteThread(String mediaId) async {
    final ThreadsClient client = await _requireLogin();
    await client.deleteThread(mediaId);
  }

  /// Insights for one of the account's posts: views, likes,
  /// replies, reposts and quotes.
  Future<ThreadsInsights> fetchThreadInsights(String mediaId) async {
    final ThreadsClient client = await _requireLogin();
    return client.getThreadInsights(mediaId);
  }

  /// Insights for the account: views, likes, replies,
  /// reposts, quotes and follower count.
  Future<ThreadsInsights> fetchAccountInsights({
    int? since,
    int? until,
  }) async {
    final ThreadsClient client = await _requireLogin();
    return client.getAccountInsights(since: since, until: until);
  }

  /// The publishing quota: how many of the 250 posts and
  /// 1,000 replies per 24 hours the account has used.
  Future<ThreadsPublishingLimit> fetchPublishingLimit() async {
    final ThreadsClient client = await _requireLogin();
    return client.getPublishingLimit();
  }

  /// The logged-in user's profile.
  Future<ThreadsUser> fetchMe() async {
    final ThreadsClient client = await _requireLogin();
    return client.getMe();
  }

  /// Starts the login flow. Threads login needs a Meta app,
  /// so the UI collects the App ID and App Secret first and
  /// calls [beginOAuthLogin]; calling [login] directly throws.
  @override
  Future<void> login() async {
    throw const ThreadsApiException(
      'Threads login needs a Meta app: use setAppCredentials, '
      'then beginOAuthLogin.',
    );
  }

  /// Starts Threads OAuth: binds a loopback listener, builds
  /// the authorize URL and returns it for the UI to open in a
  /// browser. After the user approves, Threads redirects to
  /// the loopback address and the code is captured
  /// automatically — call [completeOAuthLogin] to finish.
  /// [appId] / [appSecret] default to the stored credentials.
  Future<Uri> beginOAuthLogin({
    String? appId,
    String? appSecret,
  }) async {
    final String resolvedAppId =
        appId?.trim() ?? await this.appId ?? '';
    final String resolvedAppSecret =
        appSecret?.trim() ?? await this.appSecret ?? '';
    if (resolvedAppId.isEmpty || resolvedAppSecret.isEmpty) {
      throw const ThreadsApiException(
        'No Threads app credentials set. Create a Meta app '
        'with the Threads use case and save its Threads App ID '
        'and App Secret first.',
      );
    }
    await _ensureClient();
    await cancelOAuthLogin();
    final ThreadsLoopbackAuthListener listener =
        await ThreadsLoopbackAuthListener.start();
    final String state = _randomState();
    _pendingListener = listener;
    _pendingRedirectUri = listener.redirectUri;
    _pendingAppId = resolvedAppId;
    _pendingAppSecret = resolvedAppSecret;
    _pendingState = state;
    final Uri url = _client!.buildAuthorizeUrl(
      appId: resolvedAppId,
      redirectUri: listener.redirectUri,
      state: state,
    );
    authorizeUrl = url;
    return url;
  }

  /// Finishes Threads OAuth: waits for the loopback redirect
  /// to deliver the authorization code, exchanges it for a
  /// short-lived token, then for a long-lived token (60 days),
  /// and stores them. Throws when no login was started or the
  /// user cancelled.
  Future<void> completeOAuthLogin() async {
    final ThreadsLoopbackAuthListener? listener = _pendingListener;
    final String? redirectUri = _pendingRedirectUri;
    final String? appId = _pendingAppId;
    final String? appSecret = _pendingAppSecret;
    final String? state = _pendingState;
    if (listener == null ||
        redirectUri == null ||
        appId == null ||
        appSecret == null ||
        state == null) {
      throw const ThreadsApiException(
        'No OAuth login in progress: call beginOAuthLogin first.',
      );
    }
    final String code = await listener.code;
    // The redirect must echo the state this login sent,
    // proving it belongs to this login attempt.
    final String? returnedState = listener.state;
    if (returnedState != null && returnedState != state) {
      throw const ThreadsApiException(
        'OAuth state mismatch: the login response did not come '
        'from this login attempt.',
      );
    }
    await _exchangeAndStore(
      code: code,
      appId: appId,
      appSecret: appSecret,
      redirectUri: redirectUri,
    );
  }

  /// Finishes Threads OAuth with a manually pasted
  /// authorization code — the fallback when the loopback
  /// redirect cannot work (the code is visible in the
  /// browser's address bar after approval). Needs a login
  /// started with [beginOAuthLogin] so the redirect URI is
  /// known.
  Future<void> completeOAuthLoginWithCode(String code) async {
    final String? redirectUri = _pendingRedirectUri;
    final String? appId = _pendingAppId;
    final String? appSecret = _pendingAppSecret;
    if (redirectUri == null || appId == null || appSecret == null) {
      throw const ThreadsApiException(
        'No OAuth login in progress: call beginOAuthLogin first.',
      );
    }
    await cancelOAuthLogin();
    await _exchangeAndStore(
      code: code.trim(),
      appId: appId,
      appSecret: appSecret,
      redirectUri: redirectUri,
    );
  }

  /// Cancels a pending OAuth login (closes the loopback
  /// listener). Safe to call when no login is in progress.
  Future<void> cancelOAuthLogin() async {
    final ThreadsLoopbackAuthListener? listener = _pendingListener;
    _pendingListener = null;
    _pendingRedirectUri = null;
    _pendingAppId = null;
    _pendingAppSecret = null;
    _pendingState = null;
    authorizeUrl = null;
    if (listener != null) await listener.cancel();
  }

  Future<void> _exchangeAndStore({
    required String code,
    required String appId,
    required String appSecret,
    required String redirectUri,
  }) async {
    final ThreadsClient client = await _ensureClient();
    final ThreadsTokens shortLived = await client.exchangeCode(
      code: code,
      appId: appId,
      appSecret: appSecret,
      redirectUri: redirectUri,
    );
    final ThreadsTokens longLived = await client.exchangeLongLived(
      appSecret: appSecret,
      shortLivedToken: shortLived.accessToken,
    );
    // The long-lived exchange does not carry the user id — keep
    // the one the short-lived exchange returned.
    final ThreadsTokens stored = longLived.userId.isNotEmpty
        ? longLived
        : ThreadsTokens(
            accessToken: longLived.accessToken,
            userId: shortLived.userId,
            expiresInSeconds: longLived.expiresInSeconds,
          );
    await _storeTokens(stored);
    await cancelOAuthLogin();
  }

  /// Logs out: the access token and user id are deleted. The
  /// app credentials are kept so the next login is just one
  /// tap.
  @override
  Future<void> logout() async {
    await _accountStore.deleteToken(id);
    await _accountStore.deleteValue(_userIdKey);
    await _accountStore.deleteValue(_expiresAtKey);
    final ThreadsClient? client = _client;
    if (client != null) {
      client.accessToken = null;
      client.userId = null;
    }
  }

  Future<void> _storeTokens(ThreadsTokens tokens) async {
    await _accountStore.saveToken(id, tokens.accessToken);
    final String? uid = tokens.userId.isNotEmpty ? tokens.userId : null;
    if (uid != null) {
      await _accountStore.saveValue(_userIdKey, uid);
    }
    final DateTime? expiresAt = tokens.expiresAt;
    if (expiresAt != null) {
      await _accountStore.saveValue(
        _expiresAtKey,
        expiresAt.toIso8601String(),
      );
    }
  }

  Future<ThreadsClient> _ensureClient() async {
    final ThreadsClient? existing = _client;
    if (existing != null) {
      existing.appId = await _readValueQuiet(_appIdKey);
      existing.appSecret = await _readValueQuiet(_appSecretKey);
      existing.accessToken = await _readTokenQuiet();
      existing.userId = await _readValueQuiet(_userIdKey);
      existing.onTokensRefreshed = _storeTokens;
      await _refreshIfExpiringSoon(existing);
      return existing;
    }
    final ThreadsClient client = ThreadsClient();
    client.appId = await _readValueQuiet(_appIdKey);
    client.appSecret = await _readValueQuiet(_appSecretKey);
    client.accessToken = await _readTokenQuiet();
    client.userId = await _readValueQuiet(_userIdKey);
    client.onTokensRefreshed = _storeTokens;
    _client = client;
    await _refreshIfExpiringSoon(client);
    return client;
  }

  /// Refreshes the token proactively when it expires within
  /// 7 days (the long-lived token lives 60 days; refresh only
  /// works while it is still valid). Best effort: a failure
  /// here leaves the old token in place and the next call
  /// surfaces the real error.
  Future<void> _refreshIfExpiringSoon(ThreadsClient client) async {
    try {
      final String? raw =
          await _accountStore.readValue(_expiresAtKey);
      if (raw == null || raw.isEmpty) return;
      final DateTime? expiresAt = DateTime.tryParse(raw);
      if (expiresAt == null) return;
      final DateTime now = DateTime.now();
      if (expiresAt.isAfter(now) &&
          expiresAt.isBefore(now.add(const Duration(days: 7)))) {
        await client.refreshAccessToken();
      }
    } catch (_) {
      // Best effort only.
    }
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

  Future<ThreadsClient> _requireLogin() async {
    if (!await isLoggedIn) throw ThreadsNotLoggedInException();
    return _client!;
  }

  String _randomState() {
    final Random random = Random.secure();
    final List<int> bytes =
        List<int>.generate(16, (_) => random.nextInt(256));
    return bytes
        .map((int b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
  }
}
