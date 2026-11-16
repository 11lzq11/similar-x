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
