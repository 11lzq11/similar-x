import 'dart:math';

import '../core/account_store.dart';
import '../core/platform_adapter.dart';
import 'reddit/reddit_client.dart';
import 'reddit/reddit_models.dart';

/// Thrown when a Reddit action needs a logged-in account.
class RedditNotLoggedInException implements Exception {
  @override
  String toString() =>
      'RedditNotLoggedInException: log in to Reddit first.';
}

/// Reddit — tier 2, limited.
///
/// Data API free tier: 100 requests/minute via OAuth,
/// non-commercial use only. Since Nov 2025 every new app
/// (including free personal ones) needs manual approval,
/// usually 2–4 weeks and sometimes silently refused — until
/// the app is approved, login and the OAuth feeds fail with a
/// 401. Commercial use is $0.24/1,000 calls.
///
/// Auth is per-user, from the user's own Reddit app —
/// Similar-X ships no shared client ID:
/// * **Client ID** (reddit.com/prefs/apps > create app >
///   type **installed app** > redirect URI
///   `http://127.0.0.1`): the app identifier. Needed even for
///   guest browsing, which uses the app-only OAuth token.
/// * **OAuth** (PKCE + loopback redirect): login unlocks the
///   home feed, posting, voting, commenting, saving,
///   subscribing and the inbox. The code never leaves the
///   device; the refresh token is stored encrypted on-device.
///
/// Guests are not forced to log in: without an account the
/// timeline shows r/popular (hot). With a client ID set it is
/// fetched through the app-only token; without one it falls
/// back to the public `www.reddit.com/...json` endpoint, which
/// Reddit rate-limits hard — best effort only.
///
/// Limitation of the v0.1.0 unified [Post]: it carries no
/// subreddit field, so the timeline shows the title and
/// selftext but not which subreddit a post came from. The
/// adapter's own methods ([fetchSubreddit],
/// [fetchPostComments]) return the full [RedditPost] /
/// [RedditComment] models, which do. Reference client:
/// RedReader.
class RedditAdapter extends PlatformAdapter {
  RedditAdapter({RedditClient? client, AccountStore? accountStore}) {
    _client = client;
    _accountStore = accountStore ?? AccountStore();
  }

  static const String _clientIdKey = 'reddit_client_id';
  static const String _refreshKey = 'reddit_refresh_token';

  late final AccountStore _accountStore;
  RedditClient? _client;

  /// The authorize URL from the last [beginOAuthLogin] call, for
  /// the UI to open in a browser. Null before login starts.
  Uri? authorizeUrl;

  RedditLoopbackAuthListener? _pendingListener;
  String? _pendingVerifier;
  String? _pendingRedirectUri;
  String? _pendingClientId;
  String? _pendingState;

  @override
  String get id => 'reddit';

  @override
  String get displayName => 'Reddit';

  @override
  PlatformStatus get status => PlatformStatus.limited;

  @override
  Set<AdapterCapability> get capabilities => const <AdapterCapability>{
        AdapterCapability.timeline,
        AdapterCapability.post,
        AdapterCapability.like,
        AdapterCapability.comment,
        AdapterCapability.search,
        AdapterCapability.notifications,
      };

  @override
  String get note =>
      'Limited — free tier 100 req/min via OAuth; new Reddit '
      'apps need manual approval first (since Nov 2025, usually '
      '2–4 weeks). Login unlocks the home feed, posting, voting '
      'and inbox; guests can browse r/popular and public '
      'subreddits.';

  @override
  bool get requiresLogin => false;

  /// The stored Reddit app client ID, or null when the user
  /// has not set one.
  Future<String?> get clientId async {
    try {
      return await _accountStore.readValue(_clientIdKey);
    } catch (_) {
      return null;
    }
  }

  /// Saves the user's installed-app client ID
  /// (reddit.com/prefs/apps > create app > installed app).
  Future<void> setClientId(String id) async {
    final String trimmed = id.trim();
    if (trimmed.isEmpty) {
      throw const RedditApiException('Client ID must not be empty.');
    }
    await _accountStore.saveValue(_clientIdKey, trimmed);
    final RedditClient? client = _client;
    if (client != null) client.clientId = trimmed;
  }

  @override
  Future<bool> get isLoggedIn async {
    try {
      final String? refresh =
          await _accountStore.readValue(_refreshKey);
      if (refresh == null || refresh.isEmpty) return false;
      await _ensureClient();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// The unified timeline: the home feed (/best) when logged
  /// in, r/popular (hot) for guests.
  @override
  Future<List<Post>> fetchTimeline({int limit = 20}) async {
    if (await isLoggedIn) {
      final RedditClient client = await _requireLogin();
      final List<RedditPost> posts =
          await client.listHome(limit: limit);
      return posts.map(_toPost).toList();
    }
    final RedditClient client = await _ensureClient();
    final List<RedditPost> posts =
        await client.listPopularGuest(limit: limit);
    return posts.map(_toPost).toList();
  }

  Post _toPost(RedditPost post) {
    final String text = post.selftext.isEmpty
        ? post.title
        : '${post.title}\n\n${post.selftext}';
    return Post(
      id: 'reddit:${post.name}',
      platformId: id,
      authorName: post.author,
      authorHandle: 'u/${post.author}',
      text: text,
      createdAt: post.createdAt,
      likeCount: post.score,
      replyCount: post.commentCount,
      likedByMe: post.likes == true,
      meta: <String, String>{'subreddit': post.subreddit},
    );
  }

  /// The post fullname behind a unified [Post] (`reddit:<t3_...>`).
  String _fullnameOf(Post post) =>
      post.id.startsWith('reddit:') ? post.id.substring(7) : post.id;

  /// The subreddit a post belongs to, from [Post.meta] when present
  /// (the timeline fills it in) or by fetching the post.
  Future<String> _subredditOf(Post post) async {
    final String? subreddit = post.meta['subreddit'];
    if (subreddit != null && subreddit.isNotEmpty) return subreddit;
    final RedditPost? full = await fetchPost(_fullnameOf(post));
    final String? fetched = full?.subreddit;
    if (fetched == null || fetched.isEmpty) {
      throw const RedditApiException(
        'Could not work out which subreddit this post is in.',
      );
    }
    return fetched;
  }

  /// Submits a text post — the unified post action. Reddit needs a
  /// subreddit and a title; the title defaults to the first line of
  /// the text.
  @override
  Future<void> publishText(
    String text, {
    String? subreddit,
    String? title,
  }) async {
    final String target = subreddit?.trim() ?? '';
    if (target.isEmpty) {
      throw const RedditApiException(
        'Reddit needs a subreddit: pick one before posting.',
      );
    }
    final String postTitle = (title?.trim().isNotEmpty ?? false)
        ? title!.trim()
        : text.trim().split('\n').first;
    await submitTextPost(
      subreddit: target,
      title: postTitle,
      text: text,
    );
  }

  /// Upvotes a post.
  @override
  Future<void> like(Post post) async {
    await upvote(_fullnameOf(post));
  }

  /// Clears the vote on a post.
  @override
  Future<void> unlike(Post post) async {
    await clearVote(_fullnameOf(post));
  }

  /// Comments on a post.
  @override
  Future<void> commentOn(Post post, String text) async {
    await postComment(thingId: _fullnameOf(post), text: text);
  }

  /// The comments on a post, flattened depth-first (nested replies
  /// keep their depth in [Post.meta] so the UI can indent them).
  @override
  Future<List<Post>> fetchComments(Post post) async {
    final String subreddit = await _subredditOf(post);
    final String postId = _fullnameOf(post);
    final List<RedditComment> comments = await fetchPostComments(
      subreddit: subreddit,
      postId: postId,
    );
    final List<Post> flat = <Post>[];
    void addAll(List<RedditComment> list) {
      for (final RedditComment comment in list) {
        flat.add(
          Post(
            id: 'reddit:${comment.name}',
            platformId: id,
            authorName: comment.author,
            authorHandle: 'u/${comment.author}',
            text: comment.body,
            createdAt: comment.createdAt,
            likeCount: comment.score,
            likedByMe: false,
            meta: <String, String>{
              'depth': comment.depth.toString(),
              'subreddit': subreddit,
              'parentId': comment.parentId,
            },
          ),
        );
        addAll(comment.replies);
      }
    }

    addAll(comments);
    return flat;
  }

  /// One subreddit feed (hot/new/top/rising). Works for guests
  /// and logged-in users alike.
  Future<List<RedditPost>> fetchSubreddit(
    String subreddit, {
    String sort = 'hot',
    int limit = 25,
  }) async {
    final RedditClient client = await _ensureClient();
    return client.listSubreddit(
      subreddit: subreddit,
      sort: sort,
      limit: limit,
    );
  }

  /// Details for one subreddit, including subscriber count.
  Future<RedditSubreddit> fetchSubredditAbout(
    String subreddit,
  ) async {
    final RedditClient client = await _ensureClient();
    return client.getSubredditAbout(subreddit);
  }

  /// The comments on a post, in thread order. Works for guests
  /// and logged-in users alike.
  Future<List<RedditComment>> fetchPostComments({
    required String subreddit,
    required String postId,
    String sort = 'top',
    int limit = 100,
  }) async {
    final RedditClient client = await _ensureClient();
    return client.listComments(
      subreddit: subreddit,
      postId: postId,
      sort: sort,
      limit: limit,
    );
  }

  /// One post by fullname (`t3_...`) or short id.
  Future<RedditPost?> fetchPost(String fullnameOrId) async {
    final RedditClient client = await _ensureClient();
    return client.getPost(fullnameOrId);
  }

  /// Searches posts by keyword. Works for guests (app-only
  /// token) and logged-in users alike.
  Future<List<RedditPost>> searchPosts(
    String query, {
    int limit = 25,
  }) async {
    final RedditClient client = await _ensureClient();
    return client.searchPosts(query, limit: limit);
  }

  /// Searches subreddits by name. Works for guests and
  /// logged-in users alike.
  Future<List<RedditSubreddit>> searchSubreddits(
    String query, {
    int limit = 25,
  }) async {
    final RedditClient client = await _ensureClient();
    return client.searchSubreddits(query, limit: limit);
  }

  /// Submits a text post. OAuth only. Returns the new post's
  /// fullname (`t3_...`).
  Future<String> submitTextPost({
    required String subreddit,
    required String title,
    required String text,
  }) async {
    final RedditClient client = await _requireLogin();
    return client.submitPost(
      subreddit: subreddit,
      kind: 'self',
      title: title,
      text: text,
    );
  }

  /// Submits a link post. OAuth only. Returns the new post's
  /// fullname (`t3_...`).
  Future<String> submitLinkPost({
    required String subreddit,
    required String title,
    required String url,
  }) async {
    final RedditClient client = await _requireLogin();
    return client.submitPost(
      subreddit: subreddit,
      kind: 'link',
      title: title,
      url: url,
    );
  }

  /// Upvotes a post or comment. OAuth only.
  Future<void> upvote(String fullname) async {
    final RedditClient client = await _requireLogin();
    await client.vote(fullname: fullname, direction: 1);
  }

  /// Downvotes a post or comment. OAuth only.
  Future<void> downvote(String fullname) async {
    final RedditClient client = await _requireLogin();
    await client.vote(fullname: fullname, direction: -1);
  }

  /// Clears the vote on a post or comment. OAuth only.
  Future<void> clearVote(String fullname) async {
    final RedditClient client = await _requireLogin();
    await client.vote(fullname: fullname, direction: 0);
  }

  /// Posts a comment on a post (`t3_...`) or another comment
  /// (`t1_...`). OAuth only.
  Future<RedditComment> postComment({
    required String thingId,
    required String text,
  }) async {
    final RedditClient client = await _requireLogin();
    return client.comment(thingId: thingId, text: text);
  }

  /// Saves a post or comment. OAuth only.
  Future<void> savePost(String fullname) async {
    final RedditClient client = await _requireLogin();
    await client.save(fullname: fullname);
  }

  /// Unsaves a post or comment. OAuth only.
  Future<void> unsavePost(String fullname) async {
    final RedditClient client = await _requireLogin();
    await client.unsave(fullname: fullname);
  }

  /// Subscribes to a subreddit. OAuth only.
  Future<void> subscribeToSubreddit(String subreddit) async {
    final RedditClient client = await _requireLogin();
    await client.subscribe(subreddit: subreddit, action: 'sub');
  }

  /// Unsubscribes from a subreddit. OAuth only.
  Future<void> unsubscribeFromSubreddit(String subreddit) async {
    final RedditClient client = await _requireLogin();
    await client.subscribe(subreddit: subreddit, action: 'unsub');
  }

  /// The subreddits the user subscribes to. OAuth only.
  Future<List<RedditSubreddit>> fetchMySubreddits({
    int limit = 100,
  }) async {
    final RedditClient client = await _requireLogin();
    return client.listMySubreddits(limit: limit);
  }

  /// The user's inbox: comment replies and private messages.
  /// OAuth only.
  Future<List<RedditMessage>> fetchInbox({int limit = 25}) async {
    final RedditClient client = await _requireLogin();
    return client.listInbox(limit: limit);
  }

  /// The user's saved posts. OAuth only.
  Future<List<RedditPost>> fetchSaved({int limit = 25}) async {
    final RedditClient client = await _requireLogin();
    final RedditUser me = await client.getMe();
    return client.listSaved(username: me.name, limit: limit);
  }

  /// The user's upvoted posts. OAuth only.
  Future<List<RedditPost>> fetchUpvoted({int limit = 25}) async {
    final RedditClient client = await _requireLogin();
    final RedditUser me = await client.getMe();
    return client.listUpvoted(username: me.name, limit: limit);
  }

  /// The logged-in user's identity. OAuth only.
  Future<RedditUser> fetchMe() async {
    final RedditClient client = await _requireLogin();
    return client.getMe();
  }

  /// Starts the login flow. Reddit login needs an installed-app
  /// client ID, so the UI collects it first and calls
  /// [beginOAuthLogin]; calling [login] directly throws.
  @override
  Future<void> login() async {
    throw const RedditApiException(
      'Reddit login needs an installed-app client ID: use '
      'setClientId, then beginOAuthLogin.',
    );
  }

  /// Starts Reddit OAuth: binds a loopback listener, builds the
  /// authorize URL and returns it for the UI to open in a
  /// browser. After the user approves, Reddit redirects to the
  /// loopback address and the code is captured automatically —
  /// call [completeOAuthLogin] to finish. [clientId] defaults to
  /// the stored client ID.
  Future<Uri> beginOAuthLogin({String? clientId}) async {
    final String resolvedClientId =
        clientId?.trim() ?? await this.clientId ?? '';
    if (resolvedClientId.isEmpty) {
      throw const RedditApiException(
        'No Reddit client ID set. Create an installed app at '
        'reddit.com/prefs/apps and save its client ID first.',
      );
    }
    await _ensureClient();
    await cancelOAuthLogin();
    final String verifier = generateCodeVerifier();
    final RedditLoopbackAuthListener listener =
        await RedditLoopbackAuthListener.start();
    final String state = _randomState();
    _pendingListener = listener;
    _pendingVerifier = verifier;
    _pendingRedirectUri = listener.redirectUri;
    _pendingClientId = resolvedClientId;
    _pendingState = state;
    final Uri url = _client!.buildAuthorizeUrl(
      clientId: resolvedClientId,
      codeChallenge: codeChallengeS256(verifier),
      redirectUri: listener.redirectUri,
      state: state,
    );
    authorizeUrl = url;
    return url;
  }

  /// Finishes Reddit OAuth: waits for the loopback redirect to
  /// deliver the authorization code, exchanges it for tokens
  /// and stores them. Throws when no login was started or the
  /// user cancelled.
  Future<void> completeOAuthLogin() async {
    final RedditLoopbackAuthListener? listener = _pendingListener;
    final String? verifier = _pendingVerifier;
    final String? redirectUri = _pendingRedirectUri;
    final String? clientId = _pendingClientId;
    final String? state = _pendingState;
    if (listener == null ||
        verifier == null ||
        redirectUri == null ||
        clientId == null ||
        state == null) {
      throw const RedditApiException(
        'No OAuth login in progress: call beginOAuthLogin first.',
      );
    }
    final String code = await listener.code;
    // The redirect must echo the state this login sent,
    // proving it belongs to this login attempt.
    final String? returnedState = listener.state;
    if (returnedState != null && returnedState != state) {
      throw const RedditApiException(
        'OAuth state mismatch: the login response did not come '
        'from this login attempt.',
      );
    }
    await _exchangeAndStore(
      code: code,
      clientId: clientId,
      verifier: verifier,
      redirectUri: redirectUri,
    );
  }

  /// Finishes Reddit OAuth with a manually pasted authorization
  /// code — the fallback when the loopback redirect cannot work
  /// (the code is visible in the browser's address bar after
  /// approval). Needs a login started with [beginOAuthLogin] so
  /// the verifier and redirect URI are known.
  Future<void> completeOAuthLoginWithCode(String code) async {
    final String? verifier = _pendingVerifier;
    final String? redirectUri = _pendingRedirectUri;
    final String? clientId = _pendingClientId;
    if (verifier == null || redirectUri == null || clientId == null) {
      throw const RedditApiException(
        'No OAuth login in progress: call beginOAuthLogin first.',
      );
    }
    await cancelOAuthLogin();
    await _exchangeAndStore(
      code: code.trim(),
      clientId: clientId,
      verifier: verifier,
      redirectUri: redirectUri,
    );
  }

  /// Cancels a pending OAuth login (closes the loopback
  /// listener). Safe to call when no login is in progress.
  Future<void> cancelOAuthLogin() async {
    final RedditLoopbackAuthListener? listener = _pendingListener;
    _pendingListener = null;
    _pendingVerifier = null;
    _pendingRedirectUri = null;
    _pendingClientId = null;
    _pendingState = null;
    authorizeUrl = null;
    if (listener != null) await listener.cancel();
  }

  Future<void> _exchangeAndStore({
    required String code,
    required String clientId,
    required String verifier,
    required String redirectUri,
  }) async {
    final RedditClient client = await _ensureClient();
    final RedditTokens tokens = await client.exchangeCode(
      code: code,
      clientId: clientId,
      codeVerifier: verifier,
      redirectUri: redirectUri,
    );
    await _storeTokens(tokens);
    await cancelOAuthLogin();
  }

  /// Logs out: the access and refresh tokens are deleted. The
  /// client ID is kept so the next login is just one tap.
  @override
  Future<void> logout() async {
    await _accountStore.deleteToken(id);
    await _accountStore.deleteValue(_refreshKey);
    final RedditClient? client = _client;
    if (client != null) {
      client.accessToken = null;
      client.refreshToken = null;
      client.clearAppOnlyToken();
    }
  }

  Future<void> _storeTokens(RedditTokens tokens) async {
    await _accountStore.saveToken(id, tokens.accessToken);
    final String? refresh = tokens.refreshToken;
    if (refresh != null && refresh.isNotEmpty) {
      await _accountStore.saveValue(_refreshKey, refresh);
    }
  }

  Future<RedditClient> _ensureClient() async {
    final RedditClient? existing = _client;
    if (existing != null) {
      existing.clientId = await _readValueQuiet(_clientIdKey);
      existing.accessToken = await _readTokenQuiet();
      existing.refreshToken = await _readValueQuiet(_refreshKey);
      existing.onTokensRefreshed = _storeTokens;
      return existing;
    }
    final RedditClient client = RedditClient();
    client.clientId = await _readValueQuiet(_clientIdKey);
    client.accessToken = await _readTokenQuiet();
    client.refreshToken = await _readValueQuiet(_refreshKey);
    client.onTokensRefreshed = _storeTokens;
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

  Future<RedditClient> _requireLogin() async {
    if (!await isLoggedIn) throw RedditNotLoggedInException();
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
