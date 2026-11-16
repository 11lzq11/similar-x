import '../core/account_store.dart';
import '../core/platform_adapter.dart';
import 'youtube/youtube_client.dart';
import 'youtube/youtube_models.dart';

/// Thrown when a YouTube action needs a logged-in account.
class YouTubeNotLoggedInException implements Exception {
  @override
  String toString() =>
      'YouTubeNotLoggedInException: log in to YouTube first.';
}

/// YouTube — tier 2, limited.
///
/// Data API v3 is free but quota-tight: 10,000 units/day by
/// default and `search.list` costs 100 units per call (~100
/// searches/day). `videos.list` / `channels.list` /
/// `playlistItems.list` cost 1 unit; likes, subscribes and
/// comments cost 50 units each. The official API never serves
/// video streams — in-app playback (InnerTube) is a follow-up;
/// this adapter exposes metadata and watch URLs.
///
/// Auth is per-user, from the user's own Google Cloud project —
/// Similar-X ships no shared key:
/// * **API key** (Google Cloud Console > enable YouTube Data API
///   v3 > create an API key): covers all public reads — search,
///   video/channel details, playlists, comments. No login.
/// * **OAuth client ID** (Credentials > OAuth client ID >
///   Desktop app): login unlocks my subscriptions, likes,
///   subscribing and posting comments. Login uses PKCE with a
///   loopback redirect — the code never leaves the device.
///
/// Guests are not forced to log in: without an account the
/// timeline shows the most popular videos. Reference clients:
/// NewPipe, LibreTube (InnerTube-based, no Google account).
class YouTubeAdapter extends PlatformAdapter {
  YouTubeAdapter({YouTubeClient? client, AccountStore? accountStore}) {
    _client = client;
    _accountStore = accountStore ?? AccountStore();
  }

  static const String _apiKeyKey = 'youtube_api_key';
  static const String _oauthClientIdKey = 'youtube_oauth_client_id';
  static const String _refreshKey = 'youtube_refresh_token';

  /// The subscriptions feed reads at most this many channels
  /// (1 `channels.list` + 1 `playlistItems.list` per channel,
  /// so ~2 units each on top of the 1-unit subscriptions call).
  static const int maxFeedChannels = 10;

  /// Newest uploads fetched per subscribed channel.
  static const int maxVideosPerChannel = 3;

  late final AccountStore _accountStore;
  YouTubeClient? _client;

  /// The authorize URL from the last [beginOAuthLogin] call, for
  /// the UI to open in a browser. Null before login starts.
  Uri? authorizeUrl;

  LoopbackAuthListener? _pendingListener;
  String? _pendingVerifier;
  String? _pendingRedirectUri;
  String? _pendingClientId;

  @override
  String get id => 'youtube';

  @override
  String get displayName => 'YouTube';

  @override
  PlatformStatus get status => PlatformStatus.limited;

  @override
  Set<AdapterCapability> get capabilities => const <AdapterCapability>{
        AdapterCapability.timeline,
        AdapterCapability.search,
        AdapterCapability.like,
        AdapterCapability.comment,
      };

  @override
  String get note =>
      'Limited — Data API quota 10k units/day, search costs 100 '
      'units; login (Google OAuth) unlocks subscriptions, likes '
      'and comments. No in-app playback yet.';

  @override
  bool get requiresLogin => false;

  /// The stored API key, or null when the user has not set one.
  Future<String?> get apiKey async {
    try {
      return await _accountStore.readValue(_apiKeyKey);
    } catch (_) {
      return null;
    }
  }

  /// Saves the user's Data API v3 key. See the client docs for
  /// how to create one in Google Cloud Console.
  Future<void> setApiKey(String key) async {
    final String trimmed = key.trim();
    if (trimmed.isEmpty) {
      throw const YouTubeApiException('API key must not be empty.');
    }
    await _accountStore.saveValue(_apiKeyKey, trimmed);
    final YouTubeClient? client = _client;
    if (client != null) client.apiKey = trimmed;
  }

  /// The stored OAuth client ID, or null when not set.
  Future<String?> get oauthClientId async {
    try {
      return await _accountStore.readValue(_oauthClientIdKey);
    } catch (_) {
      return null;
    }
  }

  /// Saves the user's Desktop-app OAuth client ID (Google Cloud
  /// Console > Credentials > OAuth client ID > Desktop app).
  Future<void> setOAuthClientId(String clientId) async {
    final String trimmed = clientId.trim();
    if (trimmed.isEmpty) {
      throw const YouTubeApiException('OAuth client ID must not be empty.');
    }
    await _accountStore.saveValue(_oauthClientIdKey, trimmed);
    final YouTubeClient? client = _client;
    if (client != null) client.oauthClientId = trimmed;
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

  /// The unified timeline: the subscriptions feed when logged
  /// in (newest uploads of subscribed channels), the most
  /// popular videos for guests.
  @override
  Future<List<Post>> fetchTimeline({int limit = 20}) async {
    if (await isLoggedIn) {
      return _subscriptionsFeed(limit: limit);
    }
    final YouTubeClient client = await _ensureClient();
    final List<YouTubeVideo> videos =
        await client.listMostPopular(limit: limit);
    return videos.map(_toPost).toList();
  }

  Post _toPost(YouTubeVideo video) => Post(
        id: 'youtube:${video.id}',
        platformId: id,
        authorName: video.channelTitle,
        authorHandle: video.channelId,
        text: video.title,
        createdAt: video.publishedAt,
        likeCount: video.likeCount,
        replyCount: video.commentCount,
      );

  /// The subscriptions feed: newest uploads of the subscribed
  /// channels, newest first. Costs about 1 + 2 units per
  /// channel (subscriptions + uploads playlist + details).
  Future<List<Post>> _subscriptionsFeed({int limit = 20}) async {
    final YouTubeClient client = await _requireLogin();
    final List<YouTubeSubscription> subs =
        await client.listSubscriptions(mine: true, limit: 50);
    if (subs.isEmpty) return <Post>[];
    final List<YouTubeSubscription> channels =
        subs.take(maxFeedChannels).toList();
    final List<YouTubeChannel> details = await client.listChannels(
      channels.map((YouTubeSubscription s) => s.channelId).toList(),
    );
    final List<String> playlistIds = details
        .map((YouTubeChannel c) => c.uploadsPlaylistId)
        .whereType<String>()
        .toList();
    final List<YouTubeVideo> collected = <YouTubeVideo>[];
    for (final String playlistId in playlistIds) {
      collected.addAll(
        await client.listPlaylistItems(
          playlistId,
          limit: maxVideosPerChannel,
        ),
      );
    }
    if (collected.isEmpty) return <Post>[];
    final List<YouTubeVideo> enriched =
        await client.enrichVideos(collected);
    enriched.sort(
      (YouTubeVideo a, YouTubeVideo b) =>
          b.publishedAt.compareTo(a.publishedAt),
    );
    return enriched.take(limit).map(_toPost).toList();
  }

  /// Searches videos by keyword. Costs 100 quota units per
  /// call — use sparingly. Works with just the API key.
  Future<List<YouTubeVideo>> searchVideos(
    String query, {
    int limit = 10,
  }) async {
    final YouTubeClient client = await _ensureClient();
    return client.searchVideos(query, limit: limit);
  }

  /// Searches channels by name. Costs 100 quota units per call.
  /// Works with just the API key.
  Future<List<YouTubeChannel>> searchChannels(
    String query, {
    int limit = 10,
  }) async {
    final YouTubeClient client = await _ensureClient();
    return client.searchChannels(query, limit: limit);
  }

  /// Full details for one video (duration, views, likes,
  /// comments). Works with just the API key.
  Future<YouTubeVideo?> fetchVideoDetails(String videoId) async {
    final YouTubeClient client = await _ensureClient();
    return client.getVideo(videoId);
  }

  /// Full details for one channel, including its uploads
  /// playlist id. Works with just the API key.
  Future<YouTubeChannel?> fetchChannel(String channelId) async {
    final YouTubeClient client = await _ensureClient();
    return client.getChannel(channelId);
  }

  /// The newest uploads of a channel. Works with just the API
  /// key.
  Future<List<YouTubeVideo>> fetchChannelUploads(
    String channelId, {
    int limit = 20,
  }) async {
    final YouTubeClient client = await _ensureClient();
    final YouTubeChannel? channel = await client.getChannel(channelId);
    final String? playlistId = channel?.uploadsPlaylistId;
    if (playlistId == null || playlistId.isEmpty) {
      return <YouTubeVideo>[];
    }
    final List<YouTubeVideo> items =
        await client.listPlaylistItems(playlistId, limit: limit);
    return client.enrichVideos(items);
  }

  /// The user's subscriptions. OAuth only.
  Future<List<YouTubeSubscription>> fetchMySubscriptions({
    int limit = 50,
  }) async {
    final YouTubeClient client = await _requireLogin();
    return client.listSubscriptions(mine: true, limit: limit);
  }

  /// Top-level comments on a video, newest first. Works with
  /// just the API key.
  Future<List<YouTubeComment>> fetchComments(
    String videoId, {
    int limit = 20,
  }) async {
    final YouTubeClient client = await _ensureClient();
    return client.listCommentThreads(videoId, limit: limit);
  }

  /// Posts a top-level comment. OAuth only.
  Future<YouTubeComment> postComment(
    String videoId,
    String text,
  ) async {
    final YouTubeClient client = await _requireLogin();
    return client.postComment(videoId, text);
  }

  /// Likes a video. OAuth only.
  Future<void> likeVideo(String videoId) async {
    final YouTubeClient client = await _requireLogin();
    await client.rateVideo(videoId, rating: 'like');
  }

  /// Clears the like/dislike on a video. OAuth only.
  Future<void> unlikeVideo(String videoId) async {
    final YouTubeClient client = await _requireLogin();
    await client.rateVideo(videoId, rating: 'none');
  }

  /// Subscribes to a channel. OAuth only.
  Future<YouTubeSubscription> subscribeToChannel(
    String channelId,
  ) async {
    final YouTubeClient client = await _requireLogin();
    return client.subscribe(channelId);
  }

  /// Unsubscribes from a channel. OAuth only.
  Future<void> unsubscribeFromChannel(String channelId) async {
    final YouTubeClient client = await _requireLogin();
    final List<YouTubeSubscription> subs =
        await client.listSubscriptions(mine: true, limit: 50);
    final YouTubeSubscription sub = subs.firstWhere(
      (YouTubeSubscription s) => s.channelId == channelId,
      orElse: () => throw YouTubeApiException(
        'Not subscribed to channel $channelId.',
      ),
    );
    await client.unsubscribe(sub.id);
  }

  /// Starts the login flow. YouTube login needs an API key and a
  /// Desktop-app OAuth client ID, so the UI collects them first
  /// and calls [beginOAuthLogin]; calling [login] directly throws.
  @override
  Future<void> login() async {
    throw const YouTubeApiException(
      'YouTube login needs an API key and an OAuth client ID: '
      'use setApiKey, setOAuthClientId, then beginOAuthLogin.',
    );
  }

  /// Starts Google OAuth: binds a loopback listener, builds the
  /// authorize URL and returns it for the UI to open in a
  /// browser. After the user approves, Google redirects to the
  /// loopback address and the code is captured automatically —
  /// call [completeOAuthLogin] to finish. [clientId] defaults to
  /// the stored OAuth client ID.
  Future<Uri> beginOAuthLogin({String? clientId}) async {
    final String resolvedClientId =
        clientId?.trim() ?? await oauthClientId ?? '';
    if (resolvedClientId.isEmpty) {
      throw const YouTubeApiException(
        'No OAuth client ID set. Create a Desktop-app OAuth '
        'client ID in Google Cloud Console and save it first.',
      );
    }
    await _ensureClient();
    await cancelOAuthLogin();
    final String verifier = generateCodeVerifier();
    final LoopbackAuthListener listener =
        await LoopbackAuthListener.start();
    _pendingListener = listener;
    _pendingVerifier = verifier;
    _pendingRedirectUri = listener.redirectUri;
    _pendingClientId = resolvedClientId;
    final Uri url = _client!.buildAuthorizeUrl(
      clientId: resolvedClientId,
      codeChallenge: codeChallengeS256(verifier),
      redirectUri: listener.redirectUri,
    );
    authorizeUrl = url;
    return url;
  }

  /// Finishes Google OAuth: waits for the loopback redirect to
  /// deliver the authorization code, exchanges it for tokens
  /// and stores them. Throws when no login was started or the
  /// user cancelled.
  Future<void> completeOAuthLogin() async {
    final LoopbackAuthListener? listener = _pendingListener;
    final String? verifier = _pendingVerifier;
    final String? redirectUri = _pendingRedirectUri;
    final String? clientId = _pendingClientId;
    if (listener == null ||
        verifier == null ||
        redirectUri == null ||
        clientId == null) {
      throw const YouTubeApiException(
        'No OAuth login in progress: call beginOAuthLogin first.',
      );
    }
    final String code = await listener.code;
    await _exchangeAndStore(
      code: code,
      clientId: clientId,
      verifier: verifier,
      redirectUri: redirectUri,
    );
  }

  /// Finishes Google OAuth with a manually pasted authorization
  /// code — the fallback when the loopback redirect cannot work
  /// (the code is visible in the browser's address bar after
  /// approval). Needs a login started with [beginOAuthLogin] so
  /// the verifier and redirect URI are known.
  Future<void> completeOAuthLoginWithCode(String code) async {
    final String? verifier = _pendingVerifier;
    final String? redirectUri = _pendingRedirectUri;
    final String? clientId = _pendingClientId;
    if (verifier == null || redirectUri == null || clientId == null) {
      throw const YouTubeApiException(
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
    final LoopbackAuthListener? listener = _pendingListener;
    _pendingListener = null;
    _pendingVerifier = null;
    _pendingRedirectUri = null;
    _pendingClientId = null;
    authorizeUrl = null;
    if (listener != null) await listener.cancel();
  }

  Future<void> _exchangeAndStore({
    required String code,
    required String clientId,
    required String verifier,
    required String redirectUri,
  }) async {
    final YouTubeClient client = await _ensureClient();
    final YouTubeTokens tokens = await client.exchangeCode(
      code: code,
      clientId: clientId,
      codeVerifier: verifier,
      redirectUri: redirectUri,
    );
    await _storeTokens(tokens);
    await cancelOAuthLogin();
  }

  /// Logs out: the access and refresh tokens are deleted. The
  /// API key and OAuth client ID are kept so the next login is
  /// just one tap.
  @override
  Future<void> logout() async {
    await _accountStore.deleteToken(id);
    await _accountStore.deleteValue(_refreshKey);
    final YouTubeClient? client = _client;
    if (client != null) {
      client.accessToken = null;
      client.refreshToken = null;
    }
  }

  Future<void> _storeTokens(YouTubeTokens tokens) async {
    await _accountStore.saveToken(id, tokens.accessToken);
    final String? refresh = tokens.refreshToken;
    if (refresh != null && refresh.isNotEmpty) {
      await _accountStore.saveValue(_refreshKey, refresh);
    }
  }

  Future<YouTubeClient> _ensureClient() async {
    final YouTubeClient? existing = _client;
    if (existing != null) {
      existing.apiKey = await _readValueQuiet(_apiKeyKey);
      existing.accessToken = await _readTokenQuiet();
      existing.refreshToken = await _readValueQuiet(_refreshKey);
      existing.oauthClientId = await _readValueQuiet(_oauthClientIdKey);
      existing.onTokensRefreshed = _storeTokens;
      return existing;
    }
    final YouTubeClient client = YouTubeClient();
    client.apiKey = await _readValueQuiet(_apiKeyKey);
    client.accessToken = await _readTokenQuiet();
    client.refreshToken = await _readValueQuiet(_refreshKey);
    client.oauthClientId = await _readValueQuiet(_oauthClientIdKey);
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

  Future<YouTubeClient> _requireLogin() async {
    if (!await isLoggedIn) throw YouTubeNotLoggedInException();
    return _client!;
  }
}
