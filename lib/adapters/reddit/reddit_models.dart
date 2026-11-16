/// Data models for the Reddit Data API.
///
/// Reddit's listing endpoints return a `Listing` object:
/// `{"kind": "Listing", "data": {"children": [...], "after": ...}}`.
/// Each child has a `kind` (`t3` post, `t1` comment, `t5`
/// subreddit, `t4` private message) and a `data` map. All parsers
/// here are defensive: missing fields fall back to empty/zero
/// values and the model reports itself invalid instead of
/// throwing, so one malformed child never kills a whole feed.
library;

/// One Reddit post (`t3`).
class RedditPost {
  RedditPost({
    required this.id,
    required this.name,
    required this.title,
    required this.author,
    required this.subreddit,
    required this.subredditPrefixed,
    required this.selftext,
    required this.url,
    required this.permalink,
    required this.thumbnail,
    required this.domain,
    required this.isSelf,
    required this.over18,
    required this.saved,
    required this.likes,
    required this.score,
    required this.upvoteRatio,
    required this.commentCount,
    required this.createdAt,
  });

  /// The short id, e.g. `abc123`.
  final String id;

  /// The fullname, e.g. `t3_abc123`. Used by vote/save/comment.
  final String name;

  final String title;
  final String author;
  final String subreddit;
  final String subredditPrefixed;
  final String selftext;
  final String url;
  final String permalink;
  final String thumbnail;
  final String domain;
  final bool isSelf;
  final bool over18;

  /// Whether the logged-in user saved this post.
  final bool saved;

  /// The logged-in user's vote: true = upvoted, false =
  /// downvoted, null = no vote (or guest).
  final bool? likes;

  final int score;
  final double upvoteRatio;
  final int commentCount;
  final DateTime createdAt;

  /// The web URL of the post.
  String get webUrl => 'https://www.reddit.com$permalink';

  bool get isValid => id.isNotEmpty && title.isNotEmpty;

  factory RedditPost.fromJson(Map<String, dynamic> json) {
    final Object? likesRaw = json['likes'];
    return RedditPost(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      title: json['title'] as String? ?? '',
      author: json['author'] as String? ?? '',
      subreddit: json['subreddit'] as String? ?? '',
      subredditPrefixed:
          json['subreddit_name_prefixed'] as String? ?? '',
      selftext: json['selftext'] as String? ?? '',
      url: json['url'] as String? ?? '',
      permalink: json['permalink'] as String? ?? '',
      thumbnail: json['thumbnail'] as String? ?? '',
      domain: json['domain'] as String? ?? '',
      isSelf: json['is_self'] as bool? ?? false,
      over18: json['over_18'] as bool? ?? false,
      saved: json['saved'] as bool? ?? false,
      likes: likesRaw is bool ? likesRaw : null,
      score: (json['score'] as num?)?.toInt() ?? 0,
      upvoteRatio: (json['upvote_ratio'] as num?)?.toDouble() ?? 0.0,
      commentCount: (json['num_comments'] as num?)?.toInt() ?? 0,
      createdAt: _fromEpoch(json['created_utc']),
    );
  }
}

/// One Reddit comment (`t1`), with its nested replies.
class RedditComment {
  RedditComment({
    required this.id,
    required this.name,
    required this.body,
    required this.author,
    required this.score,
    required this.createdAt,
    required this.depth,
    required this.parentId,
    required this.linkId,
    required this.replies,
  });

  /// The short id, e.g. `abc123`.
  final String id;

  /// The fullname, e.g. `t1_abc123`.
  final String name;

  final String body;
  final String author;
  final int score;
  final DateTime createdAt;
  final int depth;
  final String parentId;
  final String linkId;

  /// Nested replies, in display order.
  final List<RedditComment> replies;

  bool get isValid => id.isNotEmpty;

  factory RedditComment.fromJson(Map<String, dynamic> json) {
    final List<RedditComment> replies = <RedditComment>[];
    final Object? repliesRaw = json['replies'];
    // Reddit returns "" for no replies and a Listing object
    // otherwise. Anything else is ignored.
    if (repliesRaw is Map<String, dynamic>) {
      final Object? data = repliesRaw['data'];
      if (data is Map<String, dynamic>) {
        final Object? children = data['children'];
        if (children is List<Object?>) {
          for (final Object? child in children) {
            if (child is Map<String, dynamic> &&
                child['kind'] == 't1') {
              final Object? childData = child['data'];
              if (childData is Map<String, dynamic>) {
                final RedditComment reply =
                    RedditComment.fromJson(childData);
                if (reply.isValid) replies.add(reply);
              }
            }
          }
        }
      }
    }
    return RedditComment(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      body: json['body'] as String? ?? '',
      author: json['author'] as String? ?? '',
      score: (json['score'] as num?)?.toInt() ?? 0,
      createdAt: _fromEpoch(json['created_utc']),
      depth: (json['depth'] as num?)?.toInt() ?? 0,
      parentId: json['parent_id'] as String? ?? '',
      linkId: json['link_id'] as String? ?? '',
      replies: replies,
    );
  }
}

/// One subreddit (`t5`).
class RedditSubreddit {
  RedditSubreddit({
    required this.name,
    required this.title,
    required this.description,
    required this.subscribers,
    required this.iconImg,
    required this.url,
    required this.over18,
    required this.subscribed,
  });

  /// The display name, e.g. `flutter`.
  final String name;

  final String title;
  final String description;
  final int subscribers;
  final String iconImg;
  final String url;
  final bool over18;

  /// Whether the logged-in user subscribes to it.
  final bool subscribed;

  String get prefixedName => 'r/$name';

  bool get isValid => name.isNotEmpty;

  factory RedditSubreddit.fromJson(Map<String, dynamic> json) {
    return RedditSubreddit(
      name: json['display_name'] as String? ?? '',
      title: json['title'] as String? ?? '',
      description: json['public_description'] as String? ?? '',
      subscribers: (json['subscribers'] as num?)?.toInt() ?? 0,
      iconImg: json['icon_img'] as String? ?? '',
      url: json['url'] as String? ?? '',
      over18: json['over_18'] as bool? ?? false,
      subscribed: json['user_is_subscriber'] as bool? ?? false,
    );
  }
}

/// One inbox item: a comment reply (`t1`) or a private message
/// (`t4`). Kept deliberately small — the unified timeline does
/// not render inboxes; the adapter only surfaces them.
class RedditMessage {
  RedditMessage({
    required this.id,
    required this.name,
    required this.subject,
    required this.body,
    required this.author,
    required this.createdAt,
    required this.isNew,
  });

  final String id;
  final String name;
  final String subject;
  final String body;
  final String author;
  final DateTime createdAt;
  final bool isNew;

  bool get isValid => id.isNotEmpty;

  factory RedditMessage.fromJson(Map<String, dynamic> json) {
    return RedditMessage(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      subject: json['subject'] as String? ?? '',
      body: json['body'] as String? ?? '',
      author: json['author'] as String? ?? '',
      createdAt: _fromEpoch(json['created_utc']),
      isNew: json['new'] as bool? ?? false,
    );
  }
}

/// The logged-in user's identity (`GET /api/v1/me`).
class RedditUser {
  RedditUser({
    required this.name,
    required this.id,
    required this.iconImg,
    required this.linkKarma,
    required this.commentKarma,
    required this.createdAt,
  });

  final String name;
  final String id;
  final String iconImg;
  final int linkKarma;
  final int commentKarma;
  final DateTime createdAt;

  bool get isValid => name.isNotEmpty;

  factory RedditUser.fromJson(Map<String, dynamic> json) {
    return RedditUser(
      name: json['name'] as String? ?? '',
      id: json['id'] as String? ?? '',
      iconImg: json['icon_img'] as String? ?? '',
      linkKarma: (json['link_karma'] as num?)?.toInt() ?? 0,
      commentKarma: (json['comment_karma'] as num?)?.toInt() ?? 0,
      createdAt: _fromEpoch(json['created_utc']),
    );
  }
}

/// OAuth tokens from Reddit's token endpoint.
class RedditTokens {
  const RedditTokens({
    required this.accessToken,
    required this.tokenType,
    required this.expiresInSeconds,
    required this.refreshToken,
    required this.scope,
  });

  final String accessToken;
  final String tokenType;
  final int expiresInSeconds;
  final String? refreshToken;
  final String scope;

  bool get isValid => accessToken.isNotEmpty;

  /// Whether this token set belongs to a logged-in user
  /// (a refresh token was issued). App-only tokens have none.
  bool get isUserToken =>
      refreshToken != null && refreshToken!.isNotEmpty;

  factory RedditTokens.fromJson(Map<String, dynamic> json) {
    return RedditTokens(
      accessToken: json['access_token'] as String? ?? '',
      tokenType: json['token_type'] as String? ?? '',
      expiresInSeconds:
          (json['expires_in'] as num?)?.toInt() ?? 3600,
      refreshToken: json['refresh_token'] as String?,
      scope: json['scope'] as String? ?? '',
    );
  }
}

DateTime _fromEpoch(Object? value) {
  if (value is num) {
    return DateTime.fromMillisecondsSinceEpoch(
      (value * 1000).round(),
      isUtc: true,
    );
  }
  return DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
}
