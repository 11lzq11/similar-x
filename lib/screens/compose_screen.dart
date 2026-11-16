import 'package:material_ui/material_ui.dart';

import '../core/app_localizations.dart';
import '../core/platform_adapter.dart';

/// The post composer: write text, pick one or more logged-in
/// platforms that support posting, publish to all of them.
///
/// Targets are the adapters with the `post` capability that the user
/// is logged in to (Mastodon, Bluesky, Threads, Reddit). Telegram
/// has no feed to post to and YouTube has no upload — they are not
/// offered here; Telegram messages are sent from a chat instead.
/// Reddit needs a subreddit (and an optional title) when selected.
class ComposeScreen extends StatefulWidget {
  const ComposeScreen({
    super.key,
    required this.adapters,
    this.preselected,
  });

  final List<PlatformAdapter> adapters;

  /// Pre-select one platform (from a platform screen).
  final String? preselected;

  @override
  State<ComposeScreen> createState() => _ComposeScreenState();
}

class _ComposeScreenState extends State<ComposeScreen> {
  final TextEditingController _textController = TextEditingController();
  final TextEditingController _subredditController =
      TextEditingController();
  final TextEditingController _titleController = TextEditingController();
  Map<String, bool> _loggedIn = <String, bool>{};
  Set<String> _selected = <String>{};
  bool _loading = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _textController.addListener(() => setState(() {}));
    _loadLoginStates();
  }

  @override
  void dispose() {
    _textController.dispose();
    _subredditController.dispose();
    _titleController.dispose();
    super.dispose();
  }

  Future<void> _loadLoginStates() async {
    final Map<String, bool> states = <String, bool>{};
    for (final PlatformAdapter adapter in widget.adapters) {
      try {
        states[adapter.id] = await adapter.isLoggedIn;
      } catch (_) {
        states[adapter.id] = false;
      }
    }
    if (!mounted) return;
    setState(() {
      _loggedIn = states;
      _loading = false;
      final Set<String> targetIds =
          _targets.map((PlatformAdapter a) => a.id).toSet();
      if (widget.preselected != null &&
          targetIds.contains(widget.preselected)) {
        _selected = <String>{widget.preselected!};
      } else {
        _selected = targetIds;
      }
    });
  }

  /// Adapters that can receive a text post: the `post` capability
  /// and a logged-in account.
  List<PlatformAdapter> get _targets => widget.adapters
      .where(
        (PlatformAdapter a) =>
            a.capabilities.contains(AdapterCapability.post) &&
            (_loggedIn[a.id] ?? false),
      )
      .toList();

  bool get _redditSelected => _selected.contains('reddit');

  bool get _threadsSelected => _selected.contains('threads');

  Future<void> _publish() async {
    final String text = _textController.text.trim();
    if (text.isEmpty || _busy || _selected.isEmpty) return;
    if (_redditSelected && _subredditController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            AppLocalizations.of(context).notSupportedFor('Reddit'),
          ),
        ),
      );
      return;
    }
    setState(() => _busy = true);
    final AppLocalizations l10n = AppLocalizations.of(context);
    final List<String> failures = <String>[];
    for (final PlatformAdapter adapter in widget.adapters) {
      if (!_selected.contains(adapter.id)) continue;
      try {
        await adapter.publishText(
          text,
          subreddit: _redditSelected
              ? _subredditController.text.trim()
              : null,
          title: _redditSelected && _titleController.text.trim().isNotEmpty
              ? _titleController.text.trim()
              : null,
        );
      } catch (e) {
        failures.add(
          l10n.postFailedFor(adapter.displayName, e.toString()),
        );
      }
    }
    if (!mounted) return;
    setState(() => _busy = false);
    if (failures.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppLocalizations.of(context).postSuccess)),
      );
      Navigator.of(context).pop(true);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(failures.join('\n'))),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final List<PlatformAdapter> targets = _targets;
    final int length = _textController.text.length;
    final bool overThreadsLimit = _threadsSelected && length > 500;
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.composeTitle),
        actions: <Widget>[
          TextButton(
            onPressed:
                _busy || _selected.isEmpty || _textController.text.trim().isEmpty
                    ? null
                    : _publish,
            child: _busy
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(l10n.composePost),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : targets.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      l10n.noPostTargets,
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      Text(l10n.selectPlatforms),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        children: <Widget>[
                          for (final PlatformAdapter adapter in targets)
                            FilterChip(
                              label: Text(adapter.displayName),
                              selected:
                                  _selected.contains(adapter.id),
                              onSelected: (bool value) {
                                setState(() {
                                  if (value) {
                                    _selected.add(adapter.id);
                                  } else {
                                    _selected.remove(adapter.id);
                                  }
                                });
                              },
                            ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      TextField(
                        controller: _textController,
                        decoration: InputDecoration(
                          hintText: l10n.composeHint,
                          border: const OutlineInputBorder(),
                        ),
                        maxLines: 8,
                        minLines: 4,
                      ),
                      const SizedBox(height: 4),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: <Widget>[
                          Text(
                            _threadsSelected
                                ? '$length / 500'
                                : '$length',
                            style: TextStyle(
                              color: overThreadsLimit
                                  ? Theme.of(context).colorScheme.error
                                  : Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                      if (_redditSelected) ...<Widget>[
                        const SizedBox(height: 8),
                        TextField(
                          controller: _subredditController,
                          decoration: InputDecoration(
                            labelText: l10n.subreddit,
                            hintText: 'flutter',
                          ),
                          textInputAction: TextInputAction.next,
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _titleController,
                          decoration: InputDecoration(
                            labelText: l10n.postTitle,
                          ),
                          textInputAction: TextInputAction.done,
                        ),
                      ],
                      const SizedBox(height: 16),
                      FilledButton(
                        onPressed: _busy ||
                                _selected.isEmpty ||
                                _textController.text.trim().isEmpty
                            ? null
                            : _publish,
                        child: _busy
                            ? Text(l10n.posting)
                            : Text(l10n.composePost),
                      ),
                    ],
                  ),
                ),
    );
  }
}
