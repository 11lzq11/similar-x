import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter_localizations/flutter_localizations.dart'
    hide GlobalCupertinoLocalizations, GlobalMaterialLocalizations;
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import 'adapters/registry.dart';
import 'core/app_localizations.dart';
import 'core/app_state.dart';
import 'screens/home_screen.dart';

void main() {
  runApp(
    ChangeNotifierProvider<AppState>(
      create: (_) => AppState(adapters: buildAdapterRegistry()),
      child: const SimilarXApp(),
    ),
  );
}

/// Similar-X — one app for every social network.
///
/// v0.1.0 is a compiling skeleton: the app shell, Chinese/English
/// locales, and the modular adapter registry. Each platform adapter is
/// a stub until its real API client lands (see lib/adapters/).
class SimilarXApp extends StatelessWidget {
  const SimilarXApp({super.key});

  @override
  Widget build(BuildContext context) {
    final AppState appState = context.watch<AppState>();
    return MaterialApp(
      onGenerateTitle: (BuildContext context) =>
          AppLocalizations.of(context).appTitle,
      locale: appState.locale,
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: const HomeScreen(),
    );
  }
}
