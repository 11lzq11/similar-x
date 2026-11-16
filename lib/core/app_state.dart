import 'package:flutter/widgets.dart';

import 'platform_adapter.dart';

/// App-wide state: which adapters are registered and which locale the
/// UI uses. Adapters are registered once and loaded lazily; nothing
/// here performs network I/O.
class AppState extends ChangeNotifier {
  AppState({required this.adapters, Locale? locale})
      : _locale = locale ?? const Locale('en');

  /// All registered platform adapters.
  final List<PlatformAdapter> adapters;

  Locale _locale;

  Locale get locale => _locale;

  void setLocale(Locale locale) {
    if (_locale == locale) return;
    _locale = locale;
    notifyListeners();
  }

  void toggleLocale() {
    setLocale(
      _locale.languageCode == 'zh' ? const Locale('en') : const Locale('zh'),
    );
  }
}
