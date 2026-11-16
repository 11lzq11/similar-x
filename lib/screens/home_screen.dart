import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../adapters/webview_adapter.dart';
import '../core/app_localizations.dart';
import '../core/app_state.dart';
import '../core/platform_adapter.dart';

/// v0.1.0 home screen: the platform list.
///
/// The unified timeline itself is not built yet — this screen shows
/// every registered adapter, its status and its feasibility note, so
/// the scaffold already communicates the product shape. Tapping an
/// adapter explains that it is a stub for now.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
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
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Text(
              l10n.unifiedTimeline,
              style: Theme.of(context).textTheme.titleLarge,
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Text(
              l10n.guestMode,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              l10n.platforms,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: adapters.length,
              itemBuilder: (BuildContext context, int index) {
                final PlatformAdapter adapter = adapters[index];
                return ListTile(
                  leading: CircleAvatar(
                    child: Text(adapter.displayName[0]),
                  ),
                  title: Text(adapter.displayName),
                  subtitle: Text(
                    adapter.note.isEmpty ? adapter.id : adapter.note,
                  ),
                  trailing: _StatusChip(status: adapter.status),
                  onTap: () {
                    if (adapter is WebViewAdapter) {
                      // WebView platforms open their embedded mobile
                      // web; every other adapter is still a stub.
                      adapter.openWebView(context);
                    } else {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text(l10n.comingSoon)),
                      );
                    }
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.status});

  final PlatformStatus status;

  @override
  Widget build(BuildContext context) {
    final String label =
        AppLocalizations.of(context).statusLabel(status);
    return Chip(label: Text(label));
  }
}
