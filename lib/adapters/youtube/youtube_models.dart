/// Plain data models for the YouTube Data API v3.
///
/// Field names follow the API's `snippet` / `contentDetails` /
/// `statistics` layout — see
/// https://developers.google.com/youtube/v3/docs
library;

/// The watch URL for a video id.
String youtubeWatchUrl(String videoId) =>
    'https://www.youtube.com/watch?v=$videoId';

/// The channel URL for a channel id.
String youtubeChannelUrl(String channelId) =>
    'https://www.youtube.com/channel/$channelId';

/// Parses an ISO 8601 duration (`PT15M33S`, `PT1H2M3S`, `P1DT2H`)
/// into a [Duration]. Returns [Duration.zero] for anything
/// unparseable — the API only ever returns this shape, so an
/// unparseable value means the field was missing.
Duration parseIso8601Duration(String? raw) {
  if (raw == null || raw.isEmpty) return Duration.zero;
  final RegExp pattern = RegExp(
    r'^P(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?$',
  );
  final RegExpMatch? match = pattern.firstMatch(raw);
  if (match == null) return Duration.zero;
  int group(int i) => int.tryParse(match.group(i) ?? '') ?? 0;
  return Duration(
    days: group(1),
    hours: group(2),
    minutes: group(3),
    seconds: group(4),
  );
}

/// Picks the best thumbnail URL from a `thumbnails` object
/// (maxres > standard > high > medium > default).
String? bestThumbnail(Map<String, dynamic>? thumbnails) {
  if (thumbnails == null) return null;
  for (final String key in <String>[
    'maxres',
    'standard',
    'high',
    'medium',
    'default',
  ]) {
    final Object? entry = thumbnails[key];
    if (entry is Map<String, dynamic>) {
      final String? url = entry['url'] as String?;
      if (url != null && url.isNotEmpty) return url;
    }
  }
  return null;
}

int _count(Object? value) {
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value) ?? 0;
  return 0;
}

DateTime _parseDate(Object? value) {
  if (value is String) {
    return DateTime.tryParse(value) ?? DateTime.fromMillisecondsSinceEpoch(0);
  }
  return DateTime.fromMillisecondsSinceEpoch(0);
}

Map<String, dynamic> _snippet(Map<String, dynamic> json) {
  final Object? snippet = json['snippet'];
  return snippet is Map<String, dynamic> ? snippet : <String, dynamic>{};
}

/// A YouTube video: from `videos.list`, `search.list` (video
/// results) or `playlistItems.list` (uploads). Statistics and
/// duration are only present when the item came from `videos.list`
/// (or was enriched with it); search and playlist items carry 0.
class YouTubeVideo {
  const YouTubeVideo({
    required this.id,
    this.title = '',
    this.channelId = '',
    this.channelTitle = '',
    this.description = '',
    required this.publishedAt,
    this.thumbnailUrl,
    this.duration = Duration.zero,
    this.viewCount = 0,
    this.likeCount = 0,
    this.commentCount = 0,
  });

  /// From a `videos.list` item (full `snippet`, `contentDetails`,
  /// `statistics`).
  factory YouTubeVideo.fromVideoJson(Map<String, dynamic> json) {
    final Map<String, dynamic> snippet = _snippet(json);
    final Object? details = json['contentDetails'];
    final Object? stats = json['statistics'];
    final Map<String, dynamic> detailsMap =
        details is Map<String, dynamic> ? details : <String, dynamic>{};
    final Map<String, dynamic> statsMap =
        stats is Map<String, dynamic> ? stats : <String, dynamic>{};
    return YouTubeVideo(
      id: (json['id'] as String?) ?? '',
      title: (snippet['title'] as String?) ?? '',
      channelId: (snippet['channelId'] as String?) ?? '',
      channelTitle: (snippet['channelTitle'] as String?) ?? '',
      description: (snippet['description'] as String?) ?? '',
      publishedAt: _parseDate(snippet['publishedAt']),
      thumbnailUrl: bestThumbnail(
        snippet['thumbnails'] as Map<String, dynamic>?,
      ),
      duration: parseIso8601Duration(
        detailsMap['duration'] as String?,
      ),
      viewCount: _count(statsMap['viewCount']),
      likeCount: _count(statsMap['likeCount']),
      commentCount: _count(statsMap['commentCount']),
    );
  }

  /// From a `search.list` item (`id.kind == 'youtube#video'`,
  /// `id.videoId` holds the id).
  factory YouTubeVideo.fromSearchJson(Map<String, dynamic> json) {
    final Map<String, dynamic> snippet = _snippet(json);
    final Object? idObj = json['id'];
    final Map<String, dynamic> idMap =
        idObj is Map<String, dynamic> ? idObj : <String, dynamic>{};
    return YouTubeVideo(
      id: (idMap['videoId'] as String?) ?? '',
      title: (snippet['title'] as String?) ?? '',
      channelId: (snippet['channelId'] as String?) ?? '',
      channelTitle: (snippet['channelTitle'] as String?) ?? '',
      description: (snippet['description'] as String?) ?? '',
      publishedAt: _parseDate(snippet['publishedAt']),
      thumbnailUrl: bestThumbnail(
        snippet['thumbnails'] as Map<String, dynamic>?,
      ),
    );
  }

  /// From a `playlistItems.list` item (`snippet.resourceId.videoId`
  /// holds the id).
  factory YouTubeVideo.fromPlaylistItemJson(Map<String, dynamic> json) {
    final Map<String, dynamic> snippet = _snippet(json);
    final Object? resource = snippet['resourceId'];
    final Map<String, dynamic> resourceMap =
        resource is Map<String, dynamic> ? resource : <String, dynamic>{};
    return YouTubeVideo(
      id: (resourceMap['videoId'] as String?) ?? '',
      title: (snippet['title'] as String?) ?? '',
      channelId: (snippet['channelId'] as String?) ?? '',
      channelTitle: (snippet['channelTitle'] as String?) ?? '',
      description: (snippet['description'] as String?) ?? '',
      publishedAt: _parseDate(snippet['publishedAt']),
      thumbnailUrl: bestThumbnail(
        snippet['thumbnails'] as Map<String, dynamic>?,
      ),
    );
  }

  final String id;
  final String title;
  final String channelId;
  final String channelTitle;
  final String description;
  final DateTime publishedAt;
  final String? thumbnailUrl;
  final Duration duration;
  final int viewCount;
  final int likeCount;
  final int commentCount;

  String get watchUrl => youtubeWatchUrl(id);

  bool get isValid => id.isNotEmpty;
}

/// A YouTube channel: from `channels.list` or `search.list`
/// (channel results).
class YouTubeChannel {
  const YouTubeChannel({
    required this.id,
    this.title = '',
    this.description = '',
    this.thumbnailUrl,
    this.subscriberCount = 0,
    this.videoCount = 0,
    this.viewCount = 0,
    this.uploadsPlaylistId,
  });

  /// From a `channels.list` item (full `snippet`,
  /// `contentDetails`, `statistics`).
  factory YouTubeChannel.fromChannelJson(Map<String, dynamic> json) {
    final Map<String, dynamic> snippet = _snippet(json);
    final Object? details = json['contentDetails'];
    final Object? stats = json['statistics'];
    final Map<String, dynamic> detailsMap =
        details is Map<String, dynamic> ? details : <String, dynamic>{};
    final Map<String, dynamic> statsMap =
        stats is Map<String, dynamic> ? stats : <String, dynamic>{};
    final Object? playlists = detailsMap['relatedPlaylists'];
    final Map<String, dynamic> playlistsMap =
        playlists is Map<String, dynamic>
            ? playlists
            : <String, dynamic>{};
    return YouTubeChannel(
      id: (json['id'] as String?) ?? '',
      title: (snippet['title'] as String?) ?? '',
      description: (snippet['description'] as String?) ?? '',
      thumbnailUrl: bestThumbnail(
        snippet['thumbnails'] as Map<String, dynamic>?,
      ),
      subscriberCount: _count(statsMap['subscriberCount']),
      videoCount: _count(statsMap['videoCount']),
      viewCount: _count(statsMap['viewCount']),
      uploadsPlaylistId: playlistsMap['uploads'] as String?,
    );
  }

  /// From a `search.list` item (`id.kind == 'youtube#channel'`).
  factory YouTubeChannel.fromSearchJson(Map<String, dynamic> json) {
    final Map<String, dynamic> snippet = _snippet(json);
    final Object? idObj = json['id'];
    final Map<String, dynamic> idMap =
        idObj is Map<String, dynamic> ? idObj : <String, dynamic>{};
    return YouTubeChannel(
      id: (idMap['channelId'] as String?) ?? '',
      title: (snippet['title'] as String?) ?? '',
      description: (snippet['description'] as String?) ?? '',
      thumbnailUrl: bestThumbnail(
        snippet['thumbnails'] as Map<String, dynamic>?,
      ),
    );
  }

  final String id;
  final String title;
  final String description;
  final String? thumbnailUrl;
  final int subscriberCount;
  final int videoCount;
  final int viewCount;

  /// The uploads playlist (`UU...`) — null when the channel came
  /// from search results, which do not include `contentDetails`.
  final String? uploadsPlaylistId;

  String get channelUrl => youtubeChannelUrl(id);

  bool get isValid => id.isNotEmpty;
}

/// One subscription: from `subscriptions.list`. [id] is the
/// subscription id (needed to unsubscribe); [channelId] is the
/// subscribed channel.
class YouTubeSubscription {
  const YouTubeSubscription({
    required this.id,
    required this.channelId,
    this.channelTitle = '',
    this.description = '',
    this.thumbnailUrl,
    required this.publishedAt,
  });

  factory YouTubeSubscription.fromJson(Map<String, dynamic> json) {
    final Map<String, dynamic> snippet = _snippet(json);
    final Object? resource = snippet['resourceId'];
    final Map<String, dynamic> resourceMap =
        resource is Map<String, dynamic> ? resource : <String, dynamic>{};
    return YouTubeSubscription(
      id: (json['id'] as String?) ?? '',
      channelId: (resourceMap['channelId'] as String?) ?? '',
      channelTitle: (snippet['title'] as String?) ?? '',
      description: (snippet['description'] as String?) ?? '',
      thumbnailUrl: bestThumbnail(
        snippet['thumbnails'] as Map<String, dynamic>?,
      ),
      publishedAt: _parseDate(snippet['publishedAt']),
    );
  }

  final String id;
  final String channelId;
  final String channelTitle;
  final String description;
  final String? thumbnailUrl;
  final DateTime publishedAt;

  bool get isValid => id.isNotEmpty && channelId.isNotEmpty;
}

/// A top-level comment: from `commentThreads.list`.
class YouTubeComment {
  const YouTubeComment({
    required this.id,
    required this.videoId,
    this.authorName = '',
    this.authorChannelId = '',
    this.authorAvatarUrl,
    this.text = '',
    this.likeCount = 0,
    required this.publishedAt,
    this.replyCount = 0,
  });

  factory YouTubeComment.fromJson(Map<String, dynamic> json) {
    final Map<String, dynamic> snippet = _snippet(json);
    final Object? topLevel = snippet['topLevelComment'];
    final Map<String, dynamic> topLevelMap =
        topLevel is Map<String, dynamic>
            ? topLevel
            : <String, dynamic>{};
    final Map<String, dynamic> commentSnippet =
        _snippet(topLevelMap);
    return YouTubeComment(
      id: (json['id'] as String?) ?? '',
      videoId: (snippet['videoId'] as String?) ?? '',
      authorName: (commentSnippet['authorDisplayName'] as String?) ?? '',
      authorChannelId:
          (commentSnippet['authorChannelId'] as Map<String, dynamic>?)?['value']
                  as String? ??
              '',
      authorAvatarUrl:
          commentSnippet['authorProfileImageUrl'] as String?,
      text: (commentSnippet['textDisplay'] as String?) ?? '',
      likeCount: _count(commentSnippet['likeCount']),
      publishedAt: _parseDate(commentSnippet['publishedAt']),
      replyCount: _count(snippet['totalReplyCount']),
    );
  }

  final String id;
  final String videoId;
  final String authorName;
  final String authorChannelId;
  final String? authorAvatarUrl;
  final String text;
  final int likeCount;
  final DateTime publishedAt;
  final int replyCount;

  bool get isValid => id.isNotEmpty;
}

/// The tokens from Google's OAuth token endpoint.
class YouTubeTokens {
  const YouTubeTokens({
    required this.accessToken,
    this.refreshToken,
    this.expiresInSeconds = 0,
  });

  factory YouTubeTokens.fromJson(Map<String, dynamic> json) =>
      YouTubeTokens(
        accessToken: (json['access_token'] as String?) ?? '',
        refreshToken: json['refresh_token'] as String?,
        expiresInSeconds: _count(json['expires_in']),
      );

  final String accessToken;
  final String? refreshToken;
  final int expiresInSeconds;

  bool get isValid => accessToken.isNotEmpty;
}
