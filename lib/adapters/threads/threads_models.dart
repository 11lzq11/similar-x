/// Data models for the Threads API (graph.threads.net, v1.0).
///
/// Threads returns plain JSON objects for media (posts), users,
/// insights and publishing quota. All parsers here are defensive:
/// missing fields fall back to empty/zero values and the model
/// reports itself invalid instead of throwing, so one malformed
/// entry never kills a whole list.
library;

/// One Threads post (a "media" object in the API).
class ThreadsPost {
  ThreadsPost({
    required this.id,
    required this.text,
    required this.username,
    required this.timestamp,
    required this.permalink,
    required this.mediaType,
    required this.mediaProductType,
    required this.mediaUrl,
    required this.thumbnailUrl,
    required this.shortcode,
    required this.isQuotePost,
    required this.isReply,
    required this.hasReplies,
    required this.hideStatus,
    required this.isVerified,
    required this.likeCount,
    required this.replyCount,
    required this.repostCount,
    required this.quoteCount,
    required this.viewCount,
    required this.quotedPost,
    required this.children,
  });

  /// The media id, e.g. `17896481123456789`.
  final String id;

  final String text;

  /// The author's Threads username (no @).
  final String username;

  /// When the post was published (ISO 8601).
  final DateTime timestamp;

  /// The web URL of the post.
  final String permalink;

  /// `TEXT`, `IMAGE`, `VIDEO`, `CAROUSEL`.
  final String mediaType;

  /// `THREADS` for a normal post, `REPOST_FACADE` for a repost.
  final String mediaProductType;

  final String mediaUrl;
  final String thumbnailUrl;

  /// The 11-character shortcode used in the post URL.
  final String shortcode;

  final bool isQuotePost;
  final bool isReply;
  final bool hasReplies;

  /// `NOT_HIDDEN`, `HIDDEN`, `HIDDEN_BY_AUTHOR`...
  final String hideStatus;
  final bool isVerified;

  /// Engagement counts. The media object does not always
  /// carry them — the insights endpoints do. Missing counts
  /// read as 0, never as an error.
  final int likeCount;
  final int replyCount;
  final int repostCount;
  final int quoteCount;
  final int viewCount;

  /// The post this one quotes, when [isQuotePost] is true.
  final ThreadsPost? quotedPost;

  /// Carousel slides. Each child is a media item, not a post.
  final List<ThreadsMediaChild> children;

  bool get isValid => id.isNotEmpty;

  bool get isRepost => mediaProductType == 'REPOST_FACADE';

  factory ThreadsPost.fromJson(Map<String, dynamic> json) {
    final Object? quotedRaw = json['quoted_post'];
    final Object? childrenRaw = json['children'];
    return ThreadsPost(
      id: json['id'] as String? ?? '',
      text: json['text'] as String? ?? '',
      username: json['username'] as String? ?? '',
      timestamp: _fromIso(json['timestamp']),
      permalink: json['permalink'] as String? ?? '',
      mediaType: json['media_type'] as String? ?? '',
      mediaProductType:
          json['media_product_type'] as String? ?? 'THREADS',
      mediaUrl: json['media_url'] as String? ?? '',
      thumbnailUrl: json['thumbnail_url'] as String? ?? '',
      shortcode: json['shortcode'] as String? ?? '',
      isQuotePost: json['is_quote_post'] as bool? ?? false,
      isReply: json['is_reply'] as bool? ?? false,
      hasReplies: json['has_replies'] as bool? ?? false,
      hideStatus: json['hide_status'] as String? ?? '',
      isVerified: json['is_verified'] as bool? ?? false,
      likeCount: (json['like_count'] as num?)?.toInt() ?? 0,
      replyCount: (json['reply_count'] as num?)?.toInt() ?? 0,
      repostCount: (json['repost_count'] as num?)?.toInt() ?? 0,
      quoteCount: (json['quote_count'] as num?)?.toInt() ?? 0,
      viewCount: (json['view_count'] as num?)?.toInt() ?? 0,
      quotedPost: quotedRaw is Map<String, dynamic>
          ? ThreadsPost.fromJson(quotedRaw)
          : null,
      children: childrenRaw is List<Object?>
          ? childrenRaw
              .whereType<Map<String, dynamic>>()
              .map(ThreadsMediaChild.fromJson)
              .toList()
          : const <ThreadsMediaChild>[],
    );
  }
}

/// One slide of a carousel post.
class ThreadsMediaChild {
  ThreadsMediaChild({
    required this.mediaType,
    required this.mediaUrl,
    required this.thumbnailUrl,
    required this.altText,
  });

  final String mediaType;
  final String mediaUrl;
  final String thumbnailUrl;
  final String altText;

  factory ThreadsMediaChild.fromJson(Map<String, dynamic> json) =>
      ThreadsMediaChild(
        mediaType: json['media_type'] as String? ?? '',
        mediaUrl: json['media_url'] as String? ?? '',
        thumbnailUrl: json['thumbnail_url'] as String? ?? '',
        altText: json['alt_text'] as String? ?? '',
      );
}

/// One Threads user (the `/me` profile).
class ThreadsUser {
  ThreadsUser({
    required this.id,
    required this.username,
    required this.name,
    required this.profilePictureUrl,
    required this.biography,
  });

  /// The Threads user id (numeric string).
  final String id;

  final String username;

  /// The display name.
  final String name;

  final String profilePictureUrl;
  final String biography;

  bool get isValid => id.isNotEmpty && username.isNotEmpty;

  factory ThreadsUser.fromJson(Map<String, dynamic> json) =>
      ThreadsUser(
        id: _stringId(json['id']),
        username: json['username'] as String? ?? '',
        name: json['name'] as String? ?? '',
        profilePictureUrl:
            json['threads_profile_picture_url'] as String? ?? '',
        biography: json['threads_biography'] as String? ?? '',
      );
}

/// The tokens from a Threads OAuth exchange.
///
/// The short-lived token (1 hour) is exchanged for a long-lived
/// one (60 days) right after login; only the long-lived token is
/// stored. There is no separate refresh token — the refresh
/// endpoint takes the current access token and returns a new
/// long-lived one, and only works while the current token is
/// still valid.
class ThreadsTokens {
  ThreadsTokens({
    required this.accessToken,
    required this.userId,
    required this.expiresInSeconds,
  });

  final String accessToken;

  /// The Threads user id the token belongs to (0 when the
  /// response did not carry one).
  final String userId;

  /// Seconds until the token expires (3600 short-lived,
  /// 5184000 long-lived).
  final int expiresInSeconds;

  bool get isValid => accessToken.isNotEmpty;

  /// When this token stops being valid, from now. Null when
  /// the lifetime is unknown.
  DateTime? get expiresAt => expiresInSeconds > 0
      ? DateTime.now().add(Duration(seconds: expiresInSeconds))
      : null;

  factory ThreadsTokens.fromJson(Map<String, dynamic> json) =>
      ThreadsTokens(
        accessToken: json['access_token'] as String? ?? '',
        userId: _stringId(json['user_id']),
        expiresInSeconds:
            (json['expires_in'] as num?)?.toInt() ?? 0,
      );
}

/// Insights for one post or for the account.
///
/// The API returns `{"data": [{"name": "views", "values":
/// [{"value": 123}], ...}]}`. [values] maps metric name to
/// value; missing metrics read as 0.
class ThreadsInsights {
  ThreadsInsights({required this.values});

  final Map<String, int> values;

  int get views => values['views'] ?? 0;
  int get likes => values['likes'] ?? 0;
  int get replies => values['replies'] ?? 0;
  int get reposts => values['reposts'] ?? 0;
  int get quotes => values['quotes'] ?? 0;
  int get shares => values['shares'] ?? 0;
  int get followersCount => values['followers_count'] ?? 0;

  factory ThreadsInsights.fromJson(Map<String, dynamic> json) {
    final Map<String, int> values = <String, int>{};
    final Object? data = json['data'];
    if (data is List<Object?>) {
      for (final Object? entry in data) {
        if (entry is! Map<String, dynamic>) continue;
        final Object? name = entry['name'];
        if (name is! String || name.isEmpty) continue;
        final Object? vals = entry['values'];
        if (vals is List<Object?> && vals.isNotEmpty) {
          final Object? first = vals.first;
          if (first is Map<String, dynamic>) {
            final Object? value = first['value'];
            if (value is num) values[name] = value.toInt();
          }
        } else {
          final Object? total = entry['total_value'];
          if (total is num) values[name] = total.toInt();
        }
      }
    }
    return ThreadsInsights(values: values);
  }
}

/// The publishing quota: how many of the daily limits the
/// account has already used.
///
/// `GET /threads_publishing_limit` returns
/// `{"data": [{"quota_usage": 3, "reply_quota_usage": 2,
/// "config": {"quota_total": 250, "reply_quota_total": 1000,
/// "quota_duration": 86400}}]}`.
class ThreadsPublishingLimit {
  ThreadsPublishingLimit({
    required this.quotaUsage,
    required this.replyQuotaUsage,
    required this.quotaTotal,
    required this.replyQuotaTotal,
    required this.quotaDurationSeconds,
  });

  /// Posts published in the current 24-hour window.
  final int quotaUsage;

  /// Replies published in the current 24-hour window.
  final int replyQuotaUsage;

  /// Daily post limit (250).
  final int quotaTotal;

  /// Daily reply limit (1000).
  final int replyQuotaTotal;

  /// Window length in seconds (86400 = 24 hours).
  final int quotaDurationSeconds;

  int get postsRemaining =>
      (quotaTotal - quotaUsage).clamp(0, quotaTotal);
  int get repliesRemaining =>
      (replyQuotaTotal - replyQuotaUsage)
          .clamp(0, replyQuotaTotal);

  factory ThreadsPublishingLimit.fromJson(Map<String, dynamic> json) {
    int quotaUsage = 0;
    int replyQuotaUsage = 0;
    int quotaTotal = 250;
    int replyQuotaTotal = 1000;
    int quotaDurationSeconds = 86400;
    final Object? data = json['data'];
    if (data is List<Object?> && data.isNotEmpty) {
      final Object? first = data.first;
      if (first is Map<String, dynamic>) {
        quotaUsage = (first['quota_usage'] as num?)?.toInt() ?? 0;
        replyQuotaUsage =
            (first['reply_quota_usage'] as num?)?.toInt() ?? 0;
        final Object? config = first['config'];
        if (config is Map<String, dynamic>) {
          quotaTotal =
              (config['quota_total'] as num?)?.toInt() ?? 250;
          replyQuotaTotal =
              (config['reply_quota_total'] as num?)?.toInt() ?? 1000;
          quotaDurationSeconds =
              (config['quota_duration'] as num?)?.toInt() ?? 86400;
        }
      }
    }
    return ThreadsPublishingLimit(
      quotaUsage: quotaUsage,
      replyQuotaUsage: replyQuotaUsage,
      quotaTotal: quotaTotal,
      replyQuotaTotal: replyQuotaTotal,
      quotaDurationSeconds: quotaDurationSeconds,
    );
  }
}

DateTime _fromIso(Object? raw) {
  if (raw is String && raw.isNotEmpty) {
    return DateTime.tryParse(raw) ?? DateTime.fromMillisecondsSinceEpoch(0);
  }
  return DateTime.fromMillisecondsSinceEpoch(0);
}

String _stringId(Object? raw) {
  if (raw is String) return raw;
  if (raw is num) return raw.toString();
  return '';
}
