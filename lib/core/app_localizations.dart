import 'package:flutter/widgets.dart';

import 'platform_adapter.dart';

/// Minimal hand-written localizations (Chinese + English).
///
/// We use the Material/Cupertino localization delegates from
/// `material_ui` / `cupertino_ui` for the framework widgets and this
/// small lookup table for our own strings, so no code generation step
/// is needed in v0.1.0. Add keys here (English + Chinese) as the UI
/// grows.
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
    'comingSoon': {
      'en': 'Coming soon — this adapter is a stub in v0.1.0.',
      'zh': '即将推出——该模块在 v0.1.0 中还是占位实现。',
    },
    'guestMode': {
      'en': 'Browsing as guest — log in to see your own timeline.',
      'zh': '游客模式浏览——登录后查看自己的时间线。',
    },
    'switchLanguage': {
      'en': 'Switch language',
      'zh': '切换语言',
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

  String get appTitle => _t('appTitle');
  String get unifiedTimeline => _t('unifiedTimeline');
  String get platforms => _t('platforms');
  String get comingSoon => _t('comingSoon');
  String get guestMode => _t('guestMode');
  String get switchLanguage => _t('switchLanguage');
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
