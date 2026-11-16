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
/// Implementations are deliberately small stubs in v0.1.0: they declare
/// their status and capabilities and return empty timelines until the
/// real API client lands. Nothing here performs network I/O yet.
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

  /// The platform timeline, newest first. Empty until implemented.
  Future<List<Post>> fetchTimeline({int limit = 20});

  /// Starts the platform login flow (OAuth / App Password / MTProto).
  /// Stub in v0.1.0.
  Future<void> login();

  /// Logs out and deletes the stored token.
  Future<void> logout();
}
