import 'package:material_ui/material_ui.dart';

import '../adapters/webview_adapter.dart';
import '../core/app_localizations.dart';
import '../core/platform_adapter.dart';
import 'compose_screen.dart';
import 'post_card.dart';
import 'post_detail_screen.dart';

/// One timeline entry: a post and the adapter it came from.
typedef TimelineEntry = ({Post post, PlatformAdapter adapter});

/// The unified timeline: guest timelines of every adapter that
/// supports guest mode, plus the home timelines of logged-in
/// adapters, merged newest-first.
///
/// One adapter failing (offline, revoked token, quota) never kills
/// the whole feed: the failure is recorded and the rest still
/// loads, with a banner naming the platforms that failed.
class TimelineScreen extends StatefulWidget {
  const TimelineScreen({super.key, required this.adapters});

  final List<PlatformAdapter> adapters;

  @override
  State<TimelineScreen> createState() => _TimelineScreenState();
}

class _TimelineScreenState extends State<TimelineScreen> {
  List<TimelineEntry> _entries = <TimelineEntry>[];
  Map<String, bool> _loggedIn = <String, bool>{};
  bool _loading = true;
  bool _allFailed = false;
  List<String> _failedPlatforms = <String>[];
  String _filter = 'all';

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// Adapters that can appear in the unified timeline (the WebView
  /// platforms have no native feed).
  List<PlatformAdapter> get _feedAdapters => widget.adapters
      .where((PlatformAdapter a) => a is! WebViewAdapter)
      .toList();

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _allFailed = false;
      _failedPlatforms = <String>[];
    });
    final Map<String, bool> loggedIn = <String, bool>{};
    final List<TimelineEntry> entries = <TimelineEntry>[];
    final List<String> failed = <String>[];
    await Future.wait(
      _feedAdapters.map((PlatformAdapter adapter) async {
        try {
          final bool isLoggedIn = await adapter.isLoggedIn;
          loggedIn[adapter.id] = isLoggedIn;
          final List<Post> posts = await adapter.fetchTimeline(limit: 20);
          entries.addAll(
            posts.map((Post p) => (post: p, adapter: adapter)),
          );
        } catch (_) {
          failed.add(adapter.displayName);
        }
      }),
    );
    entries.sort(
      (TimelineEntry a, TimelineEntry b) =>
          b.post.createdAt.compareTo(a.post.createdAt),
    );
    if (!mounted) return;
    setState(() {
      _entries = entries;
      _loggedIn = loggedIn;
      _loading = false;
      _failedPlatforms = failed;
      _allFailed = entries.isEmpty && failed.isNotEmpty;
    });
  }

  List<TimelineEntry> get _visibleEntries {
    if (_filter == 'all') return _entries;
    return _entries.where((TimelineEntry e) => e.adapter.id == _filter).toList();
  }

  bool _isLoggedIn(PlatformAdapter adapter) =>
      _loggedIn[adapter.id] ?? false;

  void _showLoginPrompt() {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(AppLocalizations.of(context).loginToInteract),
      ),
    );
  }

  void _showError(Object error) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(error.toString())),
    );
  }

  /// The like toggle for one entry, with an optimistic update.
  Future<void> _toggleLike(TimelineEntry entry) async {
    final PlatformAdapter adapter = entry.adapter;
    if (!_isLoggedIn(adapter)) {
      _showLoginPrompt();
      return;
    }
    final bool liked = entry.post.likedByMe;
    try {
      if (liked) {
        await adapter.unlike(entry.post);
      } else {
        await adapter.like(entry.post);
      }
      if (!mounted) return;
      setState(() {
        final int index = _entries.indexOf(entry);
        if (index >= 0) {
          _entries[index] = (
            post: entry.post.copyWith(likedByMe: !liked),
            adapter: adapter,
          );
        }
      });
    } catch (e) {
      _showError(e);
    }
  }

  /// The repost toggle for one entry, with an optimistic update.
  Future<void> _toggleRepost(TimelineEntry entry) async {
    final PlatformAdapter adapter = entry.adapter;
    if (!_isLoggedIn(adapter)) {
      _showLoginPrompt();
      return;
    }
    final bool reposted = entry.post.repostedByMe;
    try {
      if (reposted) {
        await adapter.unrepost(entry.post);
      } else {
        await adapter.repost(entry.post);
      }
      if (!mounted) return;
      setState(() {
        final int index = _entries.indexOf(entry);
        if (index >= 0) {
          _entries[index] = (
            post: entry.post.copyWith(repostedByMe: !reposted),
            adapter: adapter,
          );
        }
      });
    } catch (e) {
      _showError(e);
    }
  }

  Future<void> _openDetail(TimelineEntry entry) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PostDetailScreen(
          post: entry.post,
          adapter: entry.adapter,
        ),
      ),
    );
    // The detail may have changed the post (like, reply) — reload.
    if (mounted) _load();
  }

  Future<void> _openCompose() async {
    final bool? posted = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => ComposeScreen(adapters: _feedAdapters),
      ),
    );
    if (posted == true && mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final List<TimelineEntry> visible = _visibleEntries;
    return Scaffold(
      body: RefreshIndicator(
        onRefresh: _load,
        child: _loading
            ? ListView(
                children: const <Widget>[
                  SizedBox(height: 120),
                  Center(child: CircularProgressIndicator()),
                ],
              )
            : _allFailed
                ? ListView(
                    children: <Widget>[
                      const SizedBox(height: 120),
                      Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: <Widget>[
                              const Icon(Icons.cloud_off, size: 48),
                              const SizedBox(height: 16),
                              Text(l10n.timelineError),
                              const SizedBox(height: 16),
                              FilledButton(
                                onPressed: _load,
                                child: Text(l10n.retry),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  )
                : CustomScrollView(
                    slivers: <Widget>[
                      if (_failedPlatforms.isNotEmpty)
                        SliverToBoxAdapter(
                          child: Container(
                            width: double.infinity,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 8,
                            ),
                            color: Theme.of(context)
                                .colorScheme
                                .surfaceContainerHighest,
                            child: Text(
                              '${l10n.timelinePartialError} '
                              '(${_failedPlatforms.join(', ')})',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ),
                        ),
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                          child: SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: Row(
                              children: <Widget>[
                                _FilterChip(
                                  label: l10n.allPlatforms,
                                  selected: _filter == 'all',
                                  onSelected: () => setState(
                                    () => _filter = 'all',
                                  ),
                                ),
                                for (final PlatformAdapter adapter
                                    in _feedAdapters)
                                  _FilterChip(
                                    label: adapter.displayName,
                                    selected: _filter == adapter.id,
                                    onSelected: () => setState(
                                      () => _filter = adapter.id,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      if (visible.isEmpty)
                        SliverToBoxAdapter(
                          child: Padding(
                            padding: const EdgeInsets.all(32),
                            child: Center(
                              child: Text(l10n.timelineEmpty),
                            ),
                          ),
                        )
                      else
                        SliverList.builder(
                          itemCount: visible.length,
                          itemBuilder:
                              (BuildContext context, int index) {
                            final TimelineEntry entry = visible[index];
                            final PlatformAdapter adapter = entry.adapter;
                            final Set<AdapterCapability> caps =
                                adapter.capabilities;
                            return Column(
                              children: <Widget>[
                                PostCard(
                                  post: entry.post,
                                  platformName: adapter.displayName,
                                  onTap: () => _openDetail(entry),
                                  onLike: caps.contains(
                                    AdapterCapability.like,
                                  )
                                      ? () => _toggleLike(entry)
                                      : null,
                                  onRepost: caps.contains(
                                    AdapterCapability.repost,
                                  )
                                      ? () => _toggleRepost(entry)
                                      : null,
                                  onReply: caps.contains(
                                    AdapterCapability.comment,
                                  )
                                      ? () => _openDetail(entry)
                                      : null,
                                ),
                                const Divider(height: 1),
                              ],
                            );
                          },
                        ),
                    ],
                  ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _openCompose,
        tooltip: l10n.post,
        child: const Icon(Icons.edit),
      ),
    );
  }
}

class _FilterChip extends StatelessWidget {
  const _FilterChip({
    required this.label,
    required this.selected,
    required this.onSelected,
  });

  final String label;
  final bool selected;
  final VoidCallback onSelected;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ChoiceChip(
        label: Text(label),
        selected: selected,
        onSelected: (_) => onSelected(),
      ),
    );
  }
}
