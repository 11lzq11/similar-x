/// Plain data models for the Telegram adapter, mapped from TDLib JSON.
///
/// TDLib speaks JSON: every function returns a JSON object with an
/// `@type` field. These models are the small, typed surface Similar-X
/// needs (chats, messages, account); everything else stays as raw JSON
/// inside [TdlibClient].
library;

/// A Telegram chat (private chat, group, supergroup or channel).
class TelegramChat {
  const TelegramChat({
    required this.id,
    required this.title,
    required this.type,
    this.unreadCount = 0,
    this.lastMessage,
  });

  /// TDLib chat id. Positive for users/groups, negative for channels.
  final int id;

  /// Display title (chat title, or the peer's name).
  final String title;

  /// One of `private`, `group`, `supergroup`, `channel`, `secret`.
  final String type;

  final int unreadCount;

  final TelegramMessage? lastMessage;

  factory TelegramChat.fromJson(Map<String, dynamic> json) {
    final Map<String, dynamic>? typeJson =
        json['type'] as Map<String, dynamic>?;
    final String rawType = (typeJson?['@type'] as String?) ?? '';
    final String type = switch (rawType) {
      'chatTypePrivate' => 'private',
      'chatTypeBasicGroup' => 'group',
      'chatTypeSupergroup' => 'supergroup',
      'chatTypeChannel' => 'channel',
      'chatTypeSecret' => 'secret',
      _ => 'unknown',
    };
    final Map<String, dynamic>? lastJson =
        json['last_message'] as Map<String, dynamic>?;
    return TelegramChat(
      id: (json['id'] as num?)?.toInt() ?? 0,
      title: (json['title'] as String?) ?? '',
      type: type,
      unreadCount: (json['unread_count'] as num?)?.toInt() ?? 0,
      lastMessage: lastJson == null
          ? null
          : TelegramMessage.fromJson(lastJson),
    );
  }
}

/// One Telegram message.
class TelegramMessage {
  const TelegramMessage({
    required this.id,
    required this.chatId,
    required this.senderId,
    required this.senderName,
    required this.text,
    required this.date,
    required this.isOutgoing,
  });

  /// Message id, unique inside its chat.
  final int id;

  final int chatId;

  /// Sender user id (0 for channel posts).
  final int senderId;

  /// Resolved display name of the sender (`You` for own messages).
  final String senderName;

  /// Plain text of the message. Non-text content becomes a short
  /// placeholder such as `[photo]` so the timeline never shows a blank.
  final String text;

  final DateTime date;

  final bool isOutgoing;

  factory TelegramMessage.fromJson(
    Map<String, dynamic> json, {
    String senderName = '',
  }) {
    final Map<String, dynamic>? senderJson =
        json['sender_id'] as Map<String, dynamic>?;
    final int senderId = senderJson == null
        ? 0
        : (senderJson['user_id'] as num?)?.toInt() ?? 0;
    return TelegramMessage(
      id: (json['id'] as num?)?.toInt() ?? 0,
      chatId: (json['chat_id'] as num?)?.toInt() ?? 0,
      senderId: senderId,
      senderName: senderName,
      text: extractMessageText(json['content']),
      date: DateTime.fromMillisecondsSinceEpoch(
        ((json['date'] as num?)?.toInt() ?? 0) * 1000,
        isUtc: true,
      ).toLocal(),
      isOutgoing: (json['is_outgoing'] as bool?) ?? false,
    );
  }

  /// Reads the human-readable text out of a TDLib `messageContent`
  /// object. Text messages return their text; anything else returns a
  /// short placeholder so the UI never renders an empty bubble.
  static String extractMessageText(Object? content) {
    if (content is! Map<String, dynamic>) return '';
    final String type = (content['@type'] as String?) ?? '';
    if (type == 'messageText') {
      final Map<String, dynamic>? text =
          content['text'] as Map<String, dynamic>?;
      return (text?['text'] as String?) ?? '';
    }
    return switch (type) {
      'messagePhoto' => '[photo]',
      'messageVideo' => '[video]',
      'messageAnimation' => '[animation]',
      'messageAudio' => '[audio]',
      'messageVoiceNote' => '[voice message]',
      'messageVideoNote' => '[video message]',
      'messageDocument' => '[document]',
      'messageSticker' => '[sticker]',
      'messageLocation' => '[location]',
      'messagePoll' => '[poll]',
      'messageContact' => '[contact]',
      'messageCall' => '[call]',
      _ => '[message]',
    };
  }
}

/// The logged-in Telegram account (from `getMe`).
class TelegramAccount {
  const TelegramAccount({
    required this.userId,
    required this.displayName,
    required this.handle,
  });

  final int userId;
  final String displayName;

  /// @username, or '' when the account has none.
  final String handle;

  factory TelegramAccount.fromJson(Map<String, dynamic> json) {
    final String firstName = (json['first_name'] as String?) ?? '';
    final String lastName = (json['last_name'] as String?) ?? '';
    final String username = (json['usernames'] as Map<String, dynamic>?)?[
            'active_usernames'] is List
        ? (((json['usernames'] as Map<String, dynamic>)['active_usernames']
                as List)
            .firstOrNull as String?) ??
            ''
        : (json['username'] as String?) ?? '';
    final String displayName =
        [firstName, lastName].where((s) => s.isNotEmpty).join(' ');
    return TelegramAccount(
      userId: (json['id'] as num?)?.toInt() ?? 0,
      displayName: displayName.isEmpty ? username : displayName,
      handle: username,
    );
  }
}
