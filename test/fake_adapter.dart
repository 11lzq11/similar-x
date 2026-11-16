// Shared fake adapter for the UI tests: configurable timeline,
// login state and capabilities, records every action call so the
// screens can be exercised without a real account or network.

import 'package:similar_x/core/account_store.dart';
import 'package:similar_x/core/platform_adapter.dart';

/// In-memory account store: the real one wraps flutter_secure_storage,
/// which has no platform channel in tests.
class FakeAccountStore extends AccountStore {
  final Map<String, String> values = <String, String>{};

  @override
  Future<void> saveToken(String platformId, String token) async {
    values['similar_x_token_$platformId'] = token;
  }

  @override
  Future<String?> readToken(String platformId) async =>
      values['similar_x_token_$platformId'];

  @override
  Future<void> deleteToken(String platformId) async {
    values.remove('similar_x_token_$platformId');
  }

  @override
  Future<void> saveValue(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<String?> readValue(String key) async => values[key];

  @override
  Future<void> deleteValue(String key) async {
    values.remove(key);
  }
}

class FakeAdapter extends PlatformAdapter {
  FakeAdapter({
    required this.id,
    required this.displayName,
    this.status = PlatformStatus.ready,
    this.capabilities = const <AdapterCapability>{
      AdapterCapability.timeline,
    },
    this.requiresLogin = false,
    this.posts = const <Post>[],
    this.comments = const <Post>[],
    this.loggedIn = false,
    this.timelineError,
    this.loginShouldFail = false,
  });

  @override
  final String id;

  @override
  final String displayName;

  @override
  final PlatformStatus status;

  @override
  final Set<AdapterCapability> capabilities;

  @override
  final bool requiresLogin;

  /// Timeline returned by [fetchTimeline].
  List<Post> posts;

  /// Comments returned by [fetchComments].
  List<Post> comments;

  /// Current login state reported by [isLoggedIn].
  bool loggedIn;

  /// When set, [fetchTimeline] throws this instead of returning posts.
  Object? timelineError;

  /// When true, [login] throws instead of logging in.
  bool loginShouldFail;

  /// Texts passed to [publishText], in order.
  final List<String> publishedTexts = <String>[];

  /// Post ids passed to the action methods, in order.
  final List<String> likedIds = <String>[];
  final List<String> unlikedIds = <String>[];
  final List<String> repostedIds = <String>[];
  final List<String> unrepostedIds = <String>[];

  /// (post id, text) pairs passed to [commentOn], in order.
  final List<(String, String)> replies = <(String, String)>[];

  /// How many times [logout] was called.
  int logoutCalls = 0;

  @override
  Future<List<Post>> fetchTimeline({int limit = 20}) async {
    if (timelineError != null) throw timelineError!;
    return posts.take(limit).toList();
  }

  @override
  Future<bool> get isLoggedIn async => loggedIn;

  @override
  Future<void> login() async {
    if (loginShouldFail) {
      throw Exception('fake login failed');
    }
    loggedIn = true;
  }

  @override
  Future<void> logout() async {
    loggedIn = false;
    logoutCalls++;
  }

  @override
  Future<void> publishText(
    String text, {
    String? subreddit,
    String? title,
  }) async {
    publishedTexts.add(text);
  }

  @override
  Future<void> like(Post post) async {
    likedIds.add(post.id);
  }

  @override
  Future<void> unlike(Post post) async {
    unlikedIds.add(post.id);
  }

  @override
  Future<void> repost(Post post) async {
    repostedIds.add(post.id);
  }

  @override
  Future<void> unrepost(Post post) async {
    unrepostedIds.add(post.id);
  }

  @override
  Future<Post> commentOn(Post post, String text) async {
    replies.add((post.id, text));
    return Post(
      id: 'fake:comment:${replies.length}',
      platformId: id,
      authorName: 'Me',
      authorHandle: '@me',
      text: text,
      createdAt: DateTime.now(),
    );
  }

  @override
  Future<List<Post>> fetchComments(Post post) async => comments;
}

/// A post with fixed fields, for the UI tests.
Post fakePost({
  required String id,
  required String platformId,
  String authorName = 'Alice',
  String authorHandle = '@alice',
  String text = 'Hello world',
  DateTime? createdAt,
  int likeCount = 0,
  int repostCount = 0,
  int replyCount = 0,
  bool likedByMe = false,
  bool repostedByMe = false,
  Map<String, String> meta = const <String, String>{},
}) =>
    Post(
      id: id,
      platformId: platformId,
      authorName: authorName,
      authorHandle: authorHandle,
      text: text,
      createdAt: createdAt ?? DateTime(2026, 11, 17, 10, 0),
      likeCount: likeCount,
      repostCount: repostCount,
      replyCount: replyCount,
      likedByMe: likedByMe,
      repostedByMe: repostedByMe,
      meta: meta,
    );
