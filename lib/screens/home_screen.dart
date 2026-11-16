import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../core/app_localizations.dart';
import '../core/app_state.dart';
import 'platforms_screen.dart';
import 'timeline_screen.dart';

/// The home shell: two tabs — the unified timeline and the platform
/// list. The timeline merges every adapter's guest timeline (plus
/// the home timelines of logged-in adapters); the platform list
/// opens one platform's own timeline, login and posting.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _tabIndex = 0;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final adapters = context.watch<AppState>().adapters;
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.appTitle),
        actions: <Widget>[
          IconButton(
            icon: const Icon(Icons.language),
            tooltip: l10n.switchLanguage,
            onPressed: () => context.read<AppState>().toggleLocale(),
          ),
        ],
      ),
      body: _tabIndex == 0
          ? TimelineScreen(adapters: adapters)
          : PlatformsScreen(adapters: adapters),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _tabIndex,
        onTap: (int index) => setState(() => _tabIndex = index),
        items: <BottomNavigationBarItem>[
          BottomNavigationBarItem(
            icon: const Icon(Icons.home),
            label: l10n.tabTimeline,
          ),
          BottomNavigationBarItem(
            icon: const Icon(Icons.apps),
            label: l10n.tabPlatforms,
          ),
        ],
      ),
    );
  }
}
