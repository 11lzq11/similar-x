/// Plain data models for the Mastodon REST API.
///
/// Field names follow the API (`/api/v1/...`): `acct`, `display_name`,
/// `favourites_count`, `reblog`, ... — see
/// https://docs.joinmastodon.org/entities/Account/ and
/// https://docs.joinmastodon.org/entities/Status/
library;

/// Strips the HTML Mastodon wraps status content in (`<p>…</p>`,
/// `<br>`, links, mentions) down to readable plain text, so the
/// unified timeline never shows raw markup. Handles the entities
/// Mastodon actually emits; unknown entities are dropped rather than
/// leaked into the text.
String stripHtml(String html) {
  String text = html
      .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'</p\s*>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'<[^>]*>'), '');
  const Map<String, String> entities = <String, String>{
    '&amp;': '&',
    '&lt;': '<',
    '&gt;': '>',
    '&quot;': '"',
    '&apos;': "'",
    '&#39;': "'",
    '&nbsp;': ' ',
  };
  entities.forEach((String entity, String replacement) {
    text = text.replaceAll(entity, replacement);
  });
  text = text.replaceAllMapped(
    RegExp(r'&#(\d+);'),
    (Match m) =>
        String.fromCharCode(int.parse(m.group(1)!)),
  );
  text = text.replaceAllMapped(
    RegExp(r'&#x([0-9a-fA-F]+);'),
    (Match m) =>
        String.fromCharCode(int.parse(m.group(1)!, radix: 16)),
  );
  // Collapse the blank lines the </p> newlines leave behind.
  return text
      .split('\n')
      .map((String line) => line.trim())
      .where((String line) => line.isNotEmpty)
      .join('\n');
}

/// A Mastodon account (a user on any compatible instance).
class MastodonAccount {
  const MastodonAccount({
    required this.id,
    required this.username,
    required this.acct,
    required this.displayName,
    this.avatarUrl,
    this.followersCount = 0,
    this.followingCount = 0,
    this.statusesCount = 0,
    this.note = '',
  });

  factory MastodonAccount.fromJson(Map<String, dynamic> json) {
    final String noteHtml = (json['note'] as String?) ?? '';
    return MastodonAccount(
      id: (json['id'] as Object).toString(),
      username: (json['username'] as String?) ?? '',
      acct: (json['acct'] as String?) ?? '',
      displayName: (json['display_name'] as String?) ?? '',
      avatarUrl: json['avatar_static'] as String? ??
          json['avatar'] as String?,
      followersCount: (json['followers_count'] as num?)?.toInt() ?? 0,
      followingCount: (json['following_count'] as num?)?.toInt() ?? 0,
      statusesCount: (json['statuses_count'] as num?)?.toInt() ?? 0,
      note: noteHtml.isEmpty ? '' : stripHtml(noteHtml),
    );
  }

  final String id;
  final String username;
  final String acct;
  final String displayName;
  final String? avatarUrl;
  final int followersCount;
  final int followingCount;
  final int statusesCount;
  final String note;

  /// Display name if set, otherwise the username.
  String get name => displayName.isEmpty ? username : displayName;
}

/// A Mastodon status (a "toot"). When the status is a boost,
/// [reblog] holds the original status and [boostedBy] the account
/// that boosted it; the unified timeline shows the original.
class MastodonStatus {
  const MastodonStatus({
    required this.id,
    required this.account,
    required this.content,
    required this.createdAt,
    this.reblog,
    this.boostedBy,
    this.inReplyToId,
    this.reblogCount = 0,
    this.favouritesCount = 0,
    this.repliesCount = 0,
    this.favourited = false,
    this.reblogged = false,
    this.visibility = 'public',
    this.url,
  });

  factory MastodonStatus.fromJson(Map<String, dynamic> json) {
    final Map<String, dynamic>? reblogJson =
        json['reblog'] as Map<String, dynamic>?;
    final Map<String, dynamic> accountJson =
        json['account'] as Map<String, dynamic>;
    return MastodonStatus(
      id: (json['id'] as Object).toString(),
      account: MastodonAccount.fromJson(accountJson),
      content: stripHtml((json['content'] as String?) ?? ''),
      createdAt: DateTime.tryParse(
            (json['created_at'] as String?) ?? '',
          ) ??
          DateTime.fromMillisecondsSinceEpoch(0),
      reblog: reblogJson == null
          ? null
          : MastodonStatus.fromJson(reblogJson),
      boostedBy: reblogJson == null
          ? null
          : MastodonAccount.fromJson(accountJson),
      inReplyToId: json['in_reply_to_id'] == null
          ? null
          : (json['in_reply_to_id'] as Object).toString(),
      reblogCount: (json['reblogs_count'] as num?)?.toInt() ?? 0,
      favouritesCount: (json['favourites_count'] as num?)?.toInt() ?? 0,
      repliesCount: (json['replies_count'] as num?)?.toInt() ?? 0,
      favourited: json['favourited'] as bool? ?? false,
      reblogged: json['reblogged'] as bool? ?? false,
      visibility: (json['visibility'] as String?) ?? 'public',
      url: json['url'] as String?,
    );
  }

  final String id;
  final MastodonAccount account;
  final String content;
  final DateTime createdAt;
  final MastodonStatus? reblog;
  final MastodonAccount? boostedBy;
  final String? inReplyToId;
  final int reblogCount;
  final int favouritesCount;
  final int repliesCount;
  final bool favourited;
  final bool reblogged;
  final String visibility;
  final String? url;

  /// The status to display: a boost shows its original.
  MastodonStatus get displayStatus => reblog ?? this;

  bool get isBoost => reblog != null;
}

/// A Mastodon notification (mention, favourite, reblog, follow, ...).
class MastodonNotification {
  const MastodonNotification({
    required this.id,
    required this.type,
    required this.account,
    required this.createdAt,
    this.status,
  });

  factory MastodonNotification.fromJson(Map<String, dynamic> json) {
    final Map<String, dynamic>? statusJson =
        json['status'] as Map<String, dynamic>?;
    return MastodonNotification(
      id: (json['id'] as Object).toString(),
      type: (json['type'] as String?) ?? '',
      account: MastodonAccount.fromJson(
        json['account'] as Map<String, dynamic>,
      ),
      createdAt: DateTime.tryParse(
            (json['created_at'] as String?) ?? '',
          ) ??
          DateTime.fromMillisecondsSinceEpoch(0),
      status: statusJson == null
          ? null
          : MastodonStatus.fromJson(statusJson),
    );
  }

  final String id;
  final String type;
  final MastodonAccount account;
  final DateTime createdAt;
  final MastodonStatus? status;
}

/// The follow relationship with another account.
class MastodonRelationship {
  const MastodonRelationship({
    required this.id,
    required this.following,
    required this.followedBy,
  });

  factory MastodonRelationship.fromJson(Map<String, dynamic> json) =>
      MastodonRelationship(
        id: (json['id'] as Object).toString(),
        following: json['following'] as bool? ?? false,
        followedBy: json['followed_by'] as bool? ?? false,
      );

  final String id;
  final bool following;
  final bool followedBy;
}

/// One page of search results (accounts and/or statuses).
class MastodonSearchResult {
  const MastodonSearchResult({
    this.accounts = const <MastodonAccount>[],
    this.statuses = const <MastodonStatus>[],
  });

  factory MastodonSearchResult.fromJson(Map<String, dynamic> json) {
    final List<Object?> accountJson =
        (json['accounts'] as List<Object?>?) ?? const <Object?>[];
    final List<Object?> statusJson =
        (json['statuses'] as List<Object?>?) ?? const <Object?>[];
    return MastodonSearchResult(
      accounts: accountJson
          .whereType<Map<String, dynamic>>()
          .map(MastodonAccount.fromJson)
          .toList(),
      statuses: statusJson
          .whereType<Map<String, dynamic>>()
          .map(MastodonStatus.fromJson)
          .toList(),
    );
  }

  final List<MastodonAccount> accounts;
  final List<MastodonStatus> statuses;
}
