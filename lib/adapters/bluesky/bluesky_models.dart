/// Plain data models for the Bluesky / AT Protocol API.
///
/// Field names follow the AT Protocol lexicons (`app.bsky.*`,
/// `com.atproto.*`): `did`, `handle`, `displayName`, `likeCount`,
/// `repostCount`, `viewer`, ... — see https://atproto.com/specs/lexicon
/// and the API directory at https://bsky.network/docs/api-directory/
library;

/// The record key (rkey) of an AT URI: the last path segment.
/// `at://did:plc:alice/app.bsky.feed.like/3llike` -> `3llike`.
String atUriRkey(String uri) => uri.split('/').last;

/// The repo (DID) of an AT URI.
/// `at://did:plc:alice/app.bsky.feed.like/3llike` -> `did:plc:alice`.
String atUriRepo(String uri) {
  final String rest = uri.replaceFirst('at://', '');
  return rest.split('/').first;
}

/// A reference to a record: its AT URI and CID. Returned by
/// `com.atproto.repo.createRecord` and used as the `subject` of
/// likes, reposts and replies.
class BlueskyPostRef {
  const BlueskyPostRef({required this.uri, required this.cid});

  factory BlueskyPostRef.fromJson(Map<String, dynamic> json) =>
      BlueskyPostRef(
        uri: (json['uri'] as String?) ?? '',
        cid: (json['cid'] as String?) ?? '',
      );

  final String uri;
  final String cid;

  bool get isValid => uri.isNotEmpty && cid.isNotEmpty;
}

/// The reply reference of a post record: the thread root and the
/// direct parent, each as a URI + CID pair.
class BlueskyReplyRef {
  const BlueskyReplyRef({
    required this.rootUri,
    required this.rootCid,
    required this.parentUri,
    required this.parentCid,
  });

  final String rootUri;
  final String rootCid;
  final String parentUri;
  final String parentCid;
}

/// A Bluesky profile (an actor on any PDS).
class BlueskyProfile {
  const BlueskyProfile({
    required this.did,
    required this.handle,
    this.displayName = '',
    this.avatarUrl,
    this.description = '',
    this.followersCount = 0,
    this.followsCount = 0,
    this.postsCount = 0,
  });

  factory BlueskyProfile.fromJson(Map<String, dynamic> json) =>
      BlueskyProfile(
        did: (json['did'] as String?) ?? '',
        handle: (json['handle'] as String?) ?? '',
        displayName: (json['displayName'] as String?) ?? '',
        avatarUrl: json['avatar'] as String?,
        description: (json['description'] as String?) ?? '',
        followersCount: (json['followersCount'] as num?)?.toInt() ?? 0,
        followsCount: (json['followsCount'] as num?)?.toInt() ?? 0,
        postsCount: (json['postsCount'] as num?)?.toInt() ?? 0,
      );

  final String did;
  final String handle;
  final String displayName;
  final String? avatarUrl;
  final String description;
  final int followersCount;
  final int followsCount;
  final int postsCount;

  /// Display name if set, otherwise the handle.
  String get name => displayName.isEmpty ? handle : displayName;
}

/// A Bluesky post (a post view: `app.bsky.feed.defs#postView`).
/// [likeUri] / [repostUri] are the URIs of *my* like / repost
/// records when the viewer (me) liked or reposted this post — they
/// are what unlike / unrepost need.
class BlueskyPost {
  const BlueskyPost({
    required this.uri,
    required this.cid,
    required this.author,
    required this.text,
    required this.createdAt,
    this.likeCount = 0,
    this.repostCount = 0,
    this.replyCount = 0,
    this.likeUri,
    this.repostUri,
    this.replyTo,
  });

  factory BlueskyPost.fromJson(Map<String, dynamic> json) {
    final Map<String, dynamic> record =
        json['record'] as Map<String, dynamic>? ??
            const <String, dynamic>{};
    final Map<String, dynamic> authorJson =
        json['author'] as Map<String, dynamic>? ??
            const <String, dynamic>{};
    final Map<String, dynamic>? viewer =
        json['viewer'] as Map<String, dynamic>?;
    BlueskyReplyRef? replyTo;
    final Map<String, dynamic>? replyJson =
        record['reply'] as Map<String, dynamic>?;
    if (replyJson != null) {
      final Map<String, dynamic>? root =
          replyJson['root'] as Map<String, dynamic>?;
      final Map<String, dynamic>? parent =
          replyJson['parent'] as Map<String, dynamic>?;
      if (root != null && parent != null) {
        replyTo = BlueskyReplyRef(
          rootUri: (root['uri'] as String?) ?? '',
          rootCid: (root['cid'] as String?) ?? '',
          parentUri: (parent['uri'] as String?) ?? '',
          parentCid: (parent['cid'] as String?) ?? '',
        );
      }
    }
    return BlueskyPost(
      uri: (json['uri'] as String?) ?? '',
      cid: (json['cid'] as String?) ?? '',
      author: BlueskyProfile.fromJson(authorJson),
      text: (record['text'] as String?) ?? '',
      createdAt:
          DateTime.tryParse((record['createdAt'] as String?) ?? '') ??
              DateTime.fromMillisecondsSinceEpoch(0),
      likeCount: (json['likeCount'] as num?)?.toInt() ?? 0,
      repostCount: (json['repostCount'] as num?)?.toInt() ?? 0,
      replyCount: (json['replyCount'] as num?)?.toInt() ?? 0,
      likeUri: viewer?['like'] as String?,
      repostUri: viewer?['repost'] as String?,
      replyTo: replyTo,
    );
  }

  final String uri;
  final String cid;
  final BlueskyProfile author;
  final String text;
  final DateTime createdAt;
  final int likeCount;
  final int repostCount;
  final int replyCount;
  final String? likeUri;
  final String? repostUri;
  final BlueskyReplyRef? replyTo;

  bool get likedByMe => likeUri != null && likeUri!.isNotEmpty;
  bool get repostedByMe => repostUri != null && repostUri!.isNotEmpty;
}

/// One entry of a feed (`app.bsky.feed.defs#feedViewPost`).
/// When the entry is a repost, [post] is the original post and
/// [repostedBy] the account that reposted it — the unified timeline
/// shows the original, like a Mastodon boost.
class BlueskyFeedView {
  const BlueskyFeedView({required this.post, this.repostedBy});

  factory BlueskyFeedView.fromJson(Map<String, dynamic> json) {
    final Map<String, dynamic> postJson =
        json['post'] as Map<String, dynamic>;
    BlueskyProfile? repostedBy;
    final Map<String, dynamic>? reason =
        json['reason'] as Map<String, dynamic>?;
    if (reason != null &&
        reason[r'$type'] == 'app.bsky.feed.defs#reasonRepost') {
      final Map<String, dynamic>? by =
          reason['by'] as Map<String, dynamic>?;
      if (by != null) repostedBy = BlueskyProfile.fromJson(by);
    }
    return BlueskyFeedView(
      post: BlueskyPost.fromJson(postJson),
      repostedBy: repostedBy,
    );
  }

  final BlueskyPost post;
  final BlueskyProfile? repostedBy;

  bool get isRepost => repostedBy != null;
}

/// A Bluesky notification (`app.bsky.notification.listNotifications`
/// item). [reason] is `like`, `repost`, `follow`, `mention`, `reply`,
/// `quote` or `starterpack-joined`. [postUri] points at the subject
/// post when the notification is about one.
class BlueskyNotification {
  const BlueskyNotification({
    required this.uri,
    required this.reason,
    required this.author,
    required this.indexedAt,
    this.isRead = false,
    this.postUri,
  });

  factory BlueskyNotification.fromJson(Map<String, dynamic> json) {
    final String? reasonSubject =
        json['reasonSubject'] as String?;
    return BlueskyNotification(
      uri: (json['uri'] as String?) ?? '',
      reason: (json['reason'] as String?) ?? '',
      author: BlueskyProfile.fromJson(
        json['author'] as Map<String, dynamic>,
      ),
      indexedAt:
          DateTime.tryParse((json['indexedAt'] as String?) ?? '') ??
              DateTime.fromMillisecondsSinceEpoch(0),
      isRead: json['isRead'] as bool? ?? false,
      postUri: reasonSubject,
    );
  }

  final String uri;
  final String reason;
  final BlueskyProfile author;
  final DateTime indexedAt;
  final bool isRead;
  final String? postUri;
}

/// An AT Protocol session, from `com.atproto.server.createSession`
/// / `refreshSession`. The access JWT expires after about two hours;
/// the refresh JWT mints a new pair.
class BlueskySession {
  const BlueskySession({
    required this.did,
    required this.handle,
    required this.accessJwt,
    required this.refreshJwt,
  });

  factory BlueskySession.fromJson(Map<String, dynamic> json) =>
      BlueskySession(
        did: (json['did'] as String?) ?? '',
        handle: (json['handle'] as String?) ?? '',
        accessJwt: (json['accessJwt'] as String?) ?? '',
        refreshJwt: (json['refreshJwt'] as String?) ?? '',
      );

  final String did;
  final String handle;
  final String accessJwt;
  final String refreshJwt;

  bool get isValid =>
      did.isNotEmpty &&
      handle.isNotEmpty &&
      accessJwt.isNotEmpty &&
      refreshJwt.isNotEmpty;
}

/// One node of a post thread (`app.bsky.feed.defs#threadViewPost`).
/// Blocked / not-found views carry no post and are skipped by
/// [tryFromJson] instead of breaking the whole thread.
class BlueskyThreadPost {
  const BlueskyThreadPost({
    required this.post,
    this.parent,
    this.replies = const <BlueskyThreadPost>[],
  });

  factory BlueskyThreadPost.fromJson(Map<String, dynamic> json) {
    final BlueskyThreadPost? parsed = tryFromJson(json);
    if (parsed == null) {
      throw const FormatException(
        'Not a thread post view (blocked or not found).',
      );
    }
    return parsed;
  }

  static BlueskyThreadPost? tryFromJson(Map<String, dynamic> json) {
    if (json[r'$type'] != 'app.bsky.feed.defs#threadViewPost') {
      return null;
    }
    final Map<String, dynamic>? postJson =
        json['post'] as Map<String, dynamic>?;
    if (postJson == null) return null;
    final Map<String, dynamic>? parentJson =
        json['parent'] as Map<String, dynamic>?;
    final List<Object?> replyJson =
        (json['replies'] as List<Object?>?) ?? const <Object?>[];
    return BlueskyThreadPost(
      post: BlueskyPost.fromJson(postJson),
      parent: parentJson == null
          ? null
          : tryFromJson(parentJson),
      replies: replyJson
          .whereType<Map<String, dynamic>>()
          .map(tryFromJson)
          .whereType<BlueskyThreadPost>()
          .toList(),
    );
  }

  final BlueskyPost post;
  final BlueskyThreadPost? parent;
  final List<BlueskyThreadPost> replies;
}

/// One page of search results (actors and/or posts).
class BlueskySearchResult {
  const BlueskySearchResult({
    this.actors = const <BlueskyProfile>[],
    this.posts = const <BlueskyPost>[],
  });

  factory BlueskySearchResult.fromActorsJson(
    Map<String, dynamic> json,
  ) {
    final List<Object?> list =
        (json['actors'] as List<Object?>?) ?? const <Object?>[];
    return BlueskySearchResult(
      actors: list
          .whereType<Map<String, dynamic>>()
          .map(BlueskyProfile.fromJson)
          .toList(),
    );
  }

  factory BlueskySearchResult.fromPostsJson(
    Map<String, dynamic> json,
  ) {
    final List<Object?> list =
        (json['posts'] as List<Object?>?) ?? const <Object?>[];
    return BlueskySearchResult(
      posts: list
          .whereType<Map<String, dynamic>>()
          .map(BlueskyPost.fromJson)
          .toList(),
    );
  }

  final List<BlueskyProfile> actors;
  final List<BlueskyPost> posts;
}
