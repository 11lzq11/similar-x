// TinyTrainer (Flutter) — train a tiny Transformer on your phone or PC.
// Three tabs: Train / Chat / Brain. The C engine runs in a background
// isolate (see lib/engine/engine_worker.dart) so the UI never freezes.
import 'package:material_ui/material_ui.dart';

import 'l10n/strings.dart';
import 'services/training_manager.dart';
import 'ui/brain_page.dart';
import 'ui/chat_page.dart';
import 'ui/train_page.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final locale = await TrainingManager.loadLocale();
  runApp(TinyTrainerApp(initialLocale: locale));
}

class TinyTrainerApp extends StatefulWidget {
  final AppLocale initialLocale;

  const TinyTrainerApp({super.key, required this.initialLocale});

  @override
  State<TinyTrainerApp> createState() => _TinyTrainerAppState();
}

class _TinyTrainerAppState extends State<TinyTrainerApp> {
  late AppLocale _locale;
  late final TrainingManager _manager;
  int _tabIndex = 0;

  @override
  void initState() {
    super.initState();
    _locale = widget.initialLocale;
    _manager = TrainingManager();
    // Start the engine worker + restore autosave in the background.
    _manager.ensureReady();
  }

  @override
  void dispose() {
    _manager.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final strings = Strings(_locale);
    return StringsScope(
      strings: strings,
      onLocaleChanged: (locale) => setState(() => _locale = locale),
      child: MaterialApp(
        title: 'TinyTrainer',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
          useMaterial3: true,
        ),
        home: Builder(
          builder: (context) {
            final s = Strings.of(context);
            final pages = [
              TrainPage(manager: _manager),
              ChatPage(manager: _manager),
              BrainPage(manager: _manager),
            ];
            return Scaffold(
              appBar: AppBar(title: Text(s.appTitle)),
              body: IndexedStack(index: _tabIndex, children: pages),
              bottomNavigationBar: NavigationBar(
                selectedIndex: _tabIndex,
                onDestinationSelected: (i) => setState(() => _tabIndex = i),
                destinations: [
                  NavigationDestination(
                    icon: const Icon(Icons.school),
                    label: s.tabTrain,
                  ),
                  NavigationDestination(
                    icon: const Icon(Icons.chat_bubble_outline),
                    label: s.tabChat,
                  ),
                  NavigationDestination(
                    icon: const Icon(Icons.psychology),
                    label: s.tabBrain,
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}
