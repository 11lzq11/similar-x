import 'package:material_ui/material_ui.dart';

import '../adapters/webview_adapter.dart';
import '../core/app_localizations.dart';
import '../core/platform_adapter.dart';
import 'platform_screen.dart';

/// The platform list: every registered adapter, its status, its
/// feasibility note and its login state. Tapping a platform opens
/// its own timeline (WebView platforms open their embedded mobile
/// web directly).
class PlatformsScreen extends StatefulWidget {
  const PlatformsScreen({super.key, required this.adapters});

  final List<PlatformAdapter> adapters;

  @override
  State<PlatformsScreen> createState() => _PlatformsScreenState();
}

class _PlatformsScreenState extends State<PlatformsScreen> {
  Map<String, bool> _loggedIn = <String, bool>{};

  @override
  void initState() {
    super.initState();
    _refreshLoginStates();
  }

  Future<void> _refreshLoginStates() async {
    final Map<String, bool> states = <String, bool>{};
    for (final PlatformAdapter adapter in widget.adapters) {
      try {
        states[adapter.id] = await adapter.isLoggedIn;
      } catch (_) {
        states[adapter.id] = false;
      }
    }
    if (mounted) setState(() => _loggedIn = states);
  }

  Future<void> _openPlatform(PlatformAdapter adapter) async {
    if (adapter is WebViewAdapter) {
      await adapter.openWebView(context);
    } else {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => PlatformScreen(adapter: adapter),
        ),
      );
    }
    if (mounted) _refreshLoginStates();
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    return ListView.builder(
      itemCount: widget.adapters.length,
      itemBuilder: (BuildContext context, int index) {
        final PlatformAdapter adapter = widget.adapters[index];
        final bool loggedIn = _loggedIn[adapter.id] ?? false;
        return ListTile(
          leading: CircleAvatar(
            child: Text(adapter.displayName[0]),
          ),
          title: Text(adapter.displayName),
          subtitle: Text(
            adapter.note.isEmpty ? adapter.id : adapter.note,
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (loggedIn)
                Chip(
                  label: Text(l10n.loggedIn),
                  visualDensity: VisualDensity.compact,
                )
              else
                Chip(
                  label: Text(l10n.statusLabel(adapter.status)),
                  visualDensity: VisualDensity.compact,
                ),
            ],
          ),
          onTap: () => _openPlatform(adapter),
        );
      },
    );
  }
}
