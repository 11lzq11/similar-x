import 'package:flutter/widgets.dart';

import 'platform_adapter.dart';

/// Minimal hand-written localizations (Chinese + English).
///
/// We use the Material/Cupertino localization delegates from
/// `material_ui` / `cupertino_ui` for the framework widgets and this
/// small lookup table for our own strings, so no code generation step
/// is needed. Add keys here (English + Chinese) as the UI grows.
class AppLocalizations {
  AppLocalizations(this.locale);

  final Locale locale;

  static AppLocalizations of(BuildContext context) =>
      Localizations.of<AppLocalizations>(context, AppLocalizations)!;

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('zh'),
  ];

  static const Map<String, Map<String, String>> _strings =
      <String, Map<String, String>>{
    'appTitle': {
      'en': 'Similar-X',
      'zh': 'Similar-X',
    },
    'unifiedTimeline': {
      'en': 'Unified timeline',
      'zh': '聚合时间线',
    },
    'platforms': {
      'en': 'Platforms',
      'zh': '平台',
    },
    'tabTimeline': {
      'en': 'Timeline',
      'zh': '时间线',
    },
    'tabPlatforms': {
      'en': 'Platforms',
      'zh': '平台',
    },
    'statusReady': {
      'en': 'Ready',
      'zh': '可用',
    },
    'statusLimited': {
      'en': 'Limited',
      'zh': '受限',
    },
    'statusWebview': {
      'en': 'WebView',
      'zh': '网页版',
    },
    'statusPlanned': {
      'en': 'Planned',
      'zh': '计划中',
    },
    'guestMode': {
      'en': 'Browsing as guest — log in to see your own timeline.',
      'zh': '游客模式浏览——登录后查看自己的时间线。',
    },
    'switchLanguage': {
      'en': 'Switch language',
      'zh': '切换语言',
    },
    'timelineEmpty': {
      'en': 'No posts yet — pull to refresh.',
      'zh': '还没有帖子——下拉刷新试试。',
    },
    'timelineError': {
      'en': 'Couldn’t load the timeline.',
      'zh': '时间线加载失败。',
    },
    'timelinePartialError': {
      'en': 'Some platforms failed to load.',
      'zh': '部分平台加载失败。',
    },
    'retry': {
      'en': 'Retry',
      'zh': '重试',
    },
    'loading': {
      'en': 'Loading…',
      'zh': '加载中…',
    },
    'allPlatforms': {
      'en': 'All',
      'zh': '全部',
    },
    'login': {
      'en': 'Log in',
      'zh': '登录',
    },
    'logout': {
      'en': 'Log out',
      'zh': '退出登录',
    },
    'loggedIn': {
      'en': 'Logged in',
      'zh': '已登录',
    },
    'guest': {
      'en': 'Guest',
      'zh': '游客',
    },
    'post': {
      'en': 'Post',
      'zh': '发帖',
    },
    'composeTitle': {
      'en': 'New post',
      'zh': '写新帖子',
    },
    'composeHint': {
      'en': 'What’s happening?',
      'zh': '在想什么？',
    },
    'composePost': {
      'en': 'Post',
      'zh': '发布',
    },
    'posting': {
      'en': 'Posting…',
      'zh': '发布中…',
    },
    'postSuccess': {
      'en': 'Posted.',
      'zh': '发布成功。',
    },
    'postFailed': {
      'en': 'Failed to post on {platform}: {error}',
      'zh': '在 {platform} 发布失败：{error}',
    },
    'selectPlatforms': {
      'en': 'Post to',
      'zh': '发布到',
    },
    'noPostTargets': {
      'en': 'Log in to a platform that supports posting first.',
      'zh': '请先登录一个支持发帖的平台。',
    },
    'subreddit': {
      'en': 'Subreddit',
      'zh': '版块',
    },
    'postTitle': {
      'en': 'Title',
      'zh': '标题',
    },
    'comments': {
      'en': 'Comments',
      'zh': '评论',
    },
    'noComments': {
      'en': 'No comments yet.',
      'zh': '还没有评论。',
    },
    'replyHint': {
      'en': 'Write a reply…',
      'zh': '写回复…',
    },
    'reply': {
      'en': 'Reply',
      'zh': '回复',
    },
    'loginToInteract': {
      'en': 'Log in to like, repost or reply.',
      'zh': '登录后才能点赞、转发或回复。',
    },
    'notSupported': {
      'en': '{platform} doesn’t support this.',
      'zh': '{platform} 不支持这个操作。',
    },
    'like': {
      'en': 'Like',
      'zh': '点赞',
    },
    'unlike': {
      'en': 'Unlike',
      'zh': '取消点赞',
    },
    'repost': {
      'en': 'Repost',
      'zh': '转发',
    },
    'unrepost': {
      'en': 'Unrepost',
      'zh': '取消转发',
    },
    'loginTitle': {
      'en': 'Log in to {platform}',
      'zh': '登录 {platform}',
    },
    'loginFailed': {
      'en': 'Login failed: {error}',
      'zh': '登录失败：{error}',
    },
    'loginSuccess': {
      'en': 'Logged in.',
      'zh': '登录成功。',
    },
    'openInBrowser': {
      'en': 'Open in browser',
      'zh': '在浏览器中打开',
    },
    'pasteCode': {
      'en': 'Paste the code from the browser',
      'zh': '粘贴浏览器里的验证码',
    },
    'code': {
      'en': 'Code',
      'zh': '验证码',
    },
    'submit': {
      'en': 'Submit',
      'zh': '提交',
    },
    'cancel': {
      'en': 'Cancel',
      'zh': '取消',
    },
    'save': {
      'en': 'Save',
      'zh': '保存',
    },
    'instance': {
      'en': 'Instance',
      'zh': '实例',
    },
    'handle': {
      'en': 'Handle',
      'zh': '账号',
    },
    'appPassword': {
      'en': 'App Password',
      'zh': '应用密码',
    },
    'apiKey': {
      'en': 'API key',
      'zh': 'API 密钥',
    },
    'oauthClientId': {
      'en': 'OAuth client ID',
      'zh': 'OAuth 客户端 ID',
    },
    'clientId': {
      'en': 'Client ID',
      'zh': '客户端 ID',
    },
    'appId': {
      'en': 'App ID',
      'zh': '应用 ID',
    },
    'appSecret': {
      'en': 'App Secret',
      'zh': '应用密钥',
    },
    'phoneNumber': {
      'en': 'Phone number',
      'zh': '手机号',
    },
    'password': {
      'en': 'Password',
      'zh': '密码',
    },
    'waitingApproval': {
      'en': 'Waiting for approval in the browser…',
      'zh': '等待在浏览器里授权…',
    },
    'manualCodeHint': {
      'en':
          'If the browser doesn’t come back automatically, paste the code from its address bar.',
      'zh': '如果浏览器没有自动跳回，把地址栏里的验证码粘贴到这里。',
    },
    'telegramCredentialsHint': {
      'en':
          'Get api_id and api_hash at my.telegram.org, then save them.',
      'zh': '先去 my.telegram.org 获取 api_id 和 api_hash，再保存。',
    },
    'apiId': {
      'en': 'API ID',
      'zh': 'API ID',
    },
    'apiHash': {
      'en': 'API hash',
      'zh': 'API hash',
    },
    'mastodonInstanceHint': {
      'en':
          'Any Mastodon-compatible instance works (mastodon.social, etc.).',
      'zh': '任意 Mastodon 兼容实例都可以用（如 mastodon.social）。',
    },
    'blueskyAppPasswordHint': {
      'en':
          'Create an App Password in Bluesky Settings → Privacy and security → App passwords. Never use your account password.',
      'zh':
          '在 Bluesky 设置 → 隐私与安全 → 应用密码 里创建一个应用密码。不要用账号密码。',
    },
    'youtubeSetupHint': {
      'en':
          'Create an API key and a Desktop-app OAuth client ID in Google Cloud Console (YouTube Data API v3).',
      'zh':
          '在 Google Cloud Console（YouTube Data API v3）创建一个 API 密钥和桌面应用 OAuth 客户端 ID。',
    },
    'redditSetupHint': {
      'en':
          'Create an installed app at reddit.com/prefs/apps and copy its client ID.',
      'zh': '在 reddit.com/prefs/apps 创建一个 installed app，复制客户端 ID。',
    },
    'threadsSetupHint': {
      'en':
          'Create a Meta app with the Threads use case and copy its Threads App ID and App Secret.',
      'zh': '创建一个带 Threads 用例的 Meta 应用，复制 Threads 应用 ID 和密钥。',
    },
    'telegramCodeHint': {
      'en': 'Enter the code Telegram sent you.',
      'zh': '输入 Telegram 发给你的验证码。',
    },
    'telegramPasswordHint': {
      'en': 'Two-step verification is on — enter your password.',
      'zh': '开启了两步验证——请输入密码。',
    },
    'telegramPhoneHint': {
      'en': 'International format, e.g. +8613800000000.',
      'zh': '国际格式，例如 +8613800000000。',
    },
    'loginRequired': {
      'en': 'Login required',
      'zh': '需要登录',
    },
    'threadsLoginRequired': {
      'en': 'Threads has no guest mode — log in to see your own threads.',
      'zh': 'Threads 没有游客模式——登录后查看自己的帖子。',
    },
    'telegramLoginRequired': {
      'en': 'Telegram has no public timeline — log in to see your chats.',
      'zh': 'Telegram 没有公开时间线——登录后查看聊天。',
    },
    'justNow': {
      'en': 'Just now',
      'zh': '刚刚',
    },
    'minutesAgo': {
      'en': '{n}m ago',
      'zh': '{n} 分钟前',
    },
    'hoursAgo': {
      'en': '{n}h ago',
      'zh': '{n} 小时前',
    },
    'daysAgo': {
      'en': '{n}d ago',
      'zh': '{n} 天前',
    },
    'copied': {
      'en': 'Copied',
      'zh': '已复制',
    },
    'authorizeUrlLabel': {
      'en': 'Authorize URL',
      'zh': '授权链接',
    },
    'sendMessage': {
      'en': 'Send',
      'zh': '发送',
    },
    'chat': {
      'en': 'Chat',
      'zh': '聊天',
    },
    'webViewDisclaimer': {
      'en':
          'You are browsing {platform}’s mobile website inside Similar-X. Timeline, likes and comments work through the website — there is no native feed for this platform.',
      'zh':
          '你正在 Similar-X 内浏览 {platform} 的手机网页版。时间线、点赞和评论都在网页里完成——该平台没有原生信息流。',
    },
    'webViewLoggedIn': {
      'en': 'Logged in',
      'zh': '已登录',
    },
    'webViewGuest': {
      'en': 'Guest',
      'zh': '游客',
    },
    'webViewUnknown': {
      'en': 'Unknown',
      'zh': '未知',
    },
    'webViewNotAvailable': {
      'en':
          'WebView is not available here yet — on Windows and Linux it needs a community WebView plugin.',
      'zh': '这里暂不支持网页视图——Windows 和 Linux 需要社区的 WebView 插件。',
    },
    'webViewLogout': {
      'en': 'Log out',
      'zh': '退出登录',
    },
    'webViewReload': {
      'en': 'Reload',
      'zh': '重新加载',
    },
    'webViewBack': {
      'en': 'Back',
      'zh': '后退',
    },
    'webViewForward': {
      'en': 'Forward',
      'zh': '前进',
    },
    'webViewExternalBlocked': {
      'en': 'External links stay outside the app.',
      'zh': '外部链接不会在应用内打开。',
    },
  };

  String _t(String key) {
    final byKey = _strings[key];
    if (byKey == null) return key;
    return byKey[locale.languageCode] ?? byKey['en'] ?? key;
  }

  String _fill(String key, Map<String, String> values) {
    String result = _t(key);
    values.forEach((String name, String value) {
      result = result.replaceAll('{$name}', value);
    });
    return result;
  }

  String get appTitle => _t('appTitle');
  String get unifiedTimeline => _t('unifiedTimeline');
  String get platforms => _t('platforms');
  String get tabTimeline => _t('tabTimeline');
  String get tabPlatforms => _t('tabPlatforms');
  String get guestMode => _t('guestMode');
  String get switchLanguage => _t('switchLanguage');
  String get timelineEmpty => _t('timelineEmpty');
  String get timelineError => _t('timelineError');
  String get timelinePartialError => _t('timelinePartialError');
  String get retry => _t('retry');
  String get loading => _t('loading');
  String get allPlatforms => _t('allPlatforms');
  String get login => _t('login');
  String get logout => _t('logout');
  String get loggedIn => _t('loggedIn');
  String get guest => _t('guest');
  String get post => _t('post');
  String get composeTitle => _t('composeTitle');
  String get composeHint => _t('composeHint');
  String get composePost => _t('composePost');
  String get posting => _t('posting');
  String get postSuccess => _t('postSuccess');
  String get noPostTargets => _t('noPostTargets');
  String get selectPlatforms => _t('selectPlatforms');
  String get subreddit => _t('subreddit');
  String get postTitle => _t('postTitle');
  String get comments => _t('comments');
  String get noComments => _t('noComments');
  String get replyHint => _t('replyHint');
  String get reply => _t('reply');
  String get loginToInteract => _t('loginToInteract');
  String get like => _t('like');
  String get unlike => _t('unlike');
  String get repost => _t('repost');
  String get unrepost => _t('unrepost');
  String get loginFailed => _t('loginFailed');
  String get loginSuccess => _t('loginSuccess');
  String get openInBrowser => _t('openInBrowser');
  String get pasteCode => _t('pasteCode');
  String get code => _t('code');
  String get submit => _t('submit');
  String get cancel => _t('cancel');
  String get save => _t('save');
  String get instance => _t('instance');
  String get handle => _t('handle');
  String get appPassword => _t('appPassword');
  String get apiKey => _t('apiKey');
  String get oauthClientId => _t('oauthClientId');
  String get clientId => _t('clientId');
  String get appId => _t('appId');
  String get appSecret => _t('appSecret');
  String get phoneNumber => _t('phoneNumber');
  String get password => _t('password');
  String get waitingApproval => _t('waitingApproval');
  String get manualCodeHint => _t('manualCodeHint');
  String get telegramCredentialsHint => _t('telegramCredentialsHint');
  String get apiId => _t('apiId');
  String get apiHash => _t('apiHash');
  String get mastodonInstanceHint => _t('mastodonInstanceHint');
  String get blueskyAppPasswordHint => _t('blueskyAppPasswordHint');
  String get youtubeSetupHint => _t('youtubeSetupHint');
  String get redditSetupHint => _t('redditSetupHint');
  String get threadsSetupHint => _t('threadsSetupHint');
  String get telegramCodeHint => _t('telegramCodeHint');
  String get telegramPasswordHint => _t('telegramPasswordHint');
  String get telegramPhoneHint => _t('telegramPhoneHint');
  String get loginRequired => _t('loginRequired');
  String get threadsLoginRequired => _t('threadsLoginRequired');
  String get telegramLoginRequired => _t('telegramLoginRequired');
  String get justNow => _t('justNow');
  String get copied => _t('copied');
  String get authorizeUrlLabel => _t('authorizeUrlLabel');
  String get sendMessage => _t('sendMessage');
  String get chat => _t('chat');
  String get webViewLoggedIn => _t('webViewLoggedIn');
  String get webViewGuest => _t('webViewGuest');
  String get webViewUnknown => _t('webViewUnknown');
  String get webViewNotAvailable => _t('webViewNotAvailable');
  String get webViewLogout => _t('webViewLogout');
  String get webViewReload => _t('webViewReload');
  String get webViewBack => _t('webViewBack');
  String get webViewForward => _t('webViewForward');
  String get webViewExternalBlocked => _t('webViewExternalBlocked');

  /// The WebView disclaimer with the platform name filled in.
  String webViewDisclaimerFor(String platform) =>
      _t('webViewDisclaimer').replaceAll('{platform}', platform);

  /// "Failed to post on {platform}: {error}".
  String postFailedFor(String platform, String error) =>
      _fill('postFailed', <String, String>{
        'platform': platform,
        'error': error,
      });

  /// "Login failed: {error}".
  String loginFailedWith(String error) =>
      _fill('loginFailed', <String, String>{'error': error});

  /// "Log in to {platform}".
  String loginTitleFor(String platform) =>
      _fill('loginTitle', <String, String>{'platform': platform});

  /// "{platform} doesn’t support this."
  String notSupportedFor(String platform) =>
      _fill('notSupported', <String, String>{'platform': platform});

  /// "{n}m ago" / "{n}h ago" / "{n}d ago".
  String relativeTime(DateTime time) {
    final Duration diff = DateTime.now().difference(time);
    if (diff.inMinutes < 1) return justNow;
    if (diff.inHours < 1) {
      return _fill('minutesAgo', <String, String>{
        'n': diff.inMinutes.toString(),
      });
    }
    if (diff.inDays < 1) {
      return _fill('hoursAgo', <String, String>{
        'n': diff.inHours.toString(),
      });
    }
    return _fill('daysAgo', <String, String>{'n': diff.inDays.toString()});
  }

  String statusLabel(PlatformStatus status) {
    switch (status) {
      case PlatformStatus.ready:
        return _t('statusReady');
      case PlatformStatus.limited:
        return _t('statusLimited');
      case PlatformStatus.webview:
        return _t('statusWebview');
      case PlatformStatus.planned:
        return _t('statusPlanned');
    }
  }
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'zh'].contains(locale.languageCode);

  @override
  Future<AppLocalizations> load(Locale locale) async =>
      AppLocalizations(locale);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}
