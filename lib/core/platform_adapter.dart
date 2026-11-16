/// The contract every platform adapter must fulfil.
///
/// Similar-X is modular by design: each social platform lives in its own
/// adapter, and adapters are loaded lazily so the app only pays for the
/// platforms the user actually enables (keeps the install small).
/// An adapter must never send a token to a Similar-X server — there is
/// none. Tokens are stored encrypted on-device (see [AccountStore]) and
/// only ever sent to the platform's own API.
library;

/// What an adapter can do on its platform. Adapters declare only the
/// capabilities they really implement; the UI hides the rest.
enum AdapterCapability {
  timeline,
  post,
  like,
  comment,
  repost,
  directMessage,
  notifications,
  search,
}

/// How far an adapter has got. Shown in the UI so users always know
/// what to expect from a platform.
enum PlatformStatus {
  /// Fully working: login, timeline, post, like, comment, notifications.
  ready,

  /// Works, but with platform limits (own-account only, quota-limited
  /// search, read-only, ...). See the adapter's [PlatformAdapter.note].
  limited,

  /// No usable API: the official mobile web is embedded in a WebView.
  /// Login stays inside the WebView; no user token is ever touched.
  webview,

  /// Registered but not implemented yet.
  planned,
}

/// A single post in the unified timeline.
class Post {
  const Post({
    required this.id,
    required this.platformId,
    required this.authorName,
    required this.authorHandle,
    required this.text,
    required this.createdAt,
    this.likeCount = 0,
    this.repostCount = 0,
    this.replyCount = 0,
    this.likedByMe = false,
    this.repostedByMe = false,
    this.meta = const <String, String>{},
  });

  final String id;
  final String platformId;
  final String authorName;
  final String authorHandle;
  final String text;
  final DateTime createdAt;
  final int likeCount;
  final int repostCount;
  final int replyCount;

  /// Whether the logged-in account liked / reposted this post.
  /// Only set when the platform reports it; defaults to false.
  final bool likedByMe;
  final bool repostedByMe;

  /// Platform-specific data the adapter needs to act on this post,
  /// e.g. Bluesky's record CID or a like record's URI. Opaque to
  /// the UI — adapters fill it in when they build the [Post].
  final Map<String, String> meta;

  /// A copy of this post with the like / repost state flipped, for
  /// optimistic UI updates after a successful action.
  Post copyWith({bool? likedByMe, bool? repostedByMe}) => Post(
        id: id,
        platformId: platformId,
        authorName: authorName,
        authorHandle: authorHandle,
        text: text,
        createdAt: createdAt,
        likeCount: likeCount + _delta(likedByMe, this.likedByMe),
        repostCount: repostCount + _delta(repostedByMe, this.repostedByMe),
        replyCount: replyCount,
        likedByMe: likedByMe ?? this.likedByMe,
        repostedByMe: repostedByMe ?? this.repostedByMe,
        meta: meta,
      );

  static int _delta(bool? next, bool current) {
    if (next == null || next == current) return 0;
    return next ? 1 : -1;
  }
}

/// A logged-in account on one platform.
class Account {
  const Account({
    required this.platformId,
    required this.userId,
    required this.displayName,
    required this.handle,
  });

  final String platformId;
  final String userId;
  final String displayName;
  final String handle;
}

/// One social platform behind the unified timeline.
///
/// Every registered adapter is a real implementation that talks to
/// its platform's API (Telegram via TDLib, Mastodon/Bluesky/YouTube/
/// Reddit/Threads via their REST APIs, X/Instagram/Facebook via an
/// embedded WebView). The UI drives them through this contract only.
abstract class PlatformAdapter {
  const PlatformAdapter();

  /// Stable id, e.g. `telegram`. Also the key used in secure storage.
  String get id;

  /// Human-readable name, e.g. `Telegram`.
  String get displayName;

  /// How far this adapter has got.
  PlatformStatus get status;

  /// Capabilities this adapter really implements.
  Set<AdapterCapability> get capabilities;

  /// One-line note shown in the UI, e.g. why the adapter is limited.
  /// Empty when there is nothing to explain.
  String get note => '';

  /// Whether login is required for the timeline. Guests can always browse
  /// public content where the platform allows it; login is never forced.
  bool get requiresLogin => false;

  /// Whether an account is currently logged in on this platform.
  Future<bool> get isLoggedIn;

  /// The platform timeline, newest first. Guests get the platform's
  /// public content where it allows it; adapters that need an account
  /// return an empty list for guests (never fake data).
  Future<List<Post>> fetchTimeline({int limit = 20});

  /// Starts the platform login flow (OAuth / App Password / MTProto).
  /// Adapters whose login needs user input first (an instance, an
  /// App Password, API credentials) throw a descriptive exception
  /// telling the UI which method to call instead.
  Future<void> login();

  /// Logs out and deletes the stored token.
  Future<void> logout();

  /// Posts new text content (a status, toot, post or thread).
  /// Only for adapters whose [capabilities] contain
  /// [AdapterCapability.post]. [subreddit] and [title] are for
  /// Reddit, which needs both; other adapters ignore them. Throws
  /// [UnsupportedError] when the platform has no feed to post to
  /// (Telegram chats and YouTube have their own flows) and the
  /// adapter's login exception when logged out.
  Future<void> publishText(
    String text, {
    String? subreddit,
    String? title,
  }) async {
    throw UnsupportedError('$displayName has no text post to a feed.');
  }

  /// Likes the post. Only for adapters whose [capabilities] contain
  /// [AdapterCapability.like]. Throws [UnsupportedError] otherwise
  /// (Threads has no like endpoint in its official API).
  Future<void> like(Post post) async {
    throw UnsupportedError('$displayName does not support liking.');
  }

  /// Removes a like. Only for adapters whose [capabilities] contain
  /// [AdapterCapability.like].
  Future<void> unlike(Post post) async {
    throw UnsupportedError('$displayName does not support unliking.');
  }

  /// Reposts (boosts) the post. Only for adapters whose
  /// [capabilities] contain [AdapterCapability.repost].
  Future<void> repost(Post post) async {
    throw UnsupportedError('$displayName does not support reposting.');
  }

  /// Removes a repost. Only for adapters whose [capabilities]
  /// contain [AdapterCapability.repost] and whose API supports
  /// undoing a repost (Threads does not).
  Future<void> unrepost(Post post) async {
    throw UnsupportedError('$displayName does not support unreposting.');
  }

  /// Replies to / comments on the post. Only for adapters whose
  /// [capabilities] contain [AdapterCapability.comment]. For
  /// Telegram the post is a chat and the comment is a message sent
  /// to that chat.
  Future<void> commentOn(Post post, String text) async {
    throw UnsupportedError('$displayName does not support commenting.');
  }

  /// The replies / comments on the post, oldest first where the
  /// platform reports an order. Only for adapters whose
  /// [capabilities] contain [AdapterCapability.comment]. For
  /// Telegram the post is a chat and the comments are its messages.
  /// Returns an empty list when the platform has no comment thread
  /// for this post.
  Future<List<Post>> fetchComments(Post post) async =>
      const <Post>[];
}
