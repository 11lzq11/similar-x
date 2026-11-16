import 'package:material_ui/material_ui.dart';

import '../core/app_localizations.dart';
import '../core/platform_adapter.dart';
import 'compose_screen.dart';
import 'login_screen.dart';
import 'post_card.dart';
import 'post_detail_screen.dart';

/// One platform's own timeline: its posts, a login button and a
/// post button. Platforms that require login (Telegram, Threads)
/// show a login prompt instead of an empty timeline when logged
/// out — the timeline is empty there by design, never fake data.
class PlatformScreen extends StatefulWidget {
  const PlatformScreen({super.key, required this.adapter});

  final PlatformAdapter adapter;

  @override
  State<PlatformScreen> createState() => _PlatformScreenState();
}

class _PlatformScreenState extends State<PlatformScreen> {
  List<Post> _posts = <Post>[];
  bool _loading = true;
  bool _loggedIn = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    bool loggedIn = false;
    List<Post> posts = <Post>[];
    Object? error;
    try {
      loggedIn = await widget.adapter.isLoggedIn;
    } catch (_) {
      loggedIn = false;
    }
    try {
      posts = await widget.adapter.fetchTimeline(limit: 20);
    } catch (e) {
      error = e;
    }
    if (!mounted) return;
    setState(() {
      _loggedIn = loggedIn;
      _posts = posts;
      _loading = false;
      _error = error;
    });
  }

  Future<void> _openLogin() async {
    final bool? loggedIn = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => LoginScreen(adapter: widget.adapter),
      ),
    );
    if (loggedIn == true && mounted) _load();
  }

  Future<void> _logout() async {
    try {
      await widget.adapter.logout();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.toString())),
        );
      }
      return;
    }
    if (mounted) _load();
  }

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

  Future<void> _toggleLike(Post post) async {
    if (!_loggedIn) {
      _showLoginPrompt();
      return;
    }
    final bool liked = post.likedByMe;
    try {
      if (liked) {
        await widget.adapter.unlike(post);
      } else {
        await widget.adapter.like(post);
      }
      if (!mounted) return;
      setState(() {
        final int index = _posts.indexOf(post);
        if (index >= 0) {
          _posts[index] = post.copyWith(likedByMe: !liked);
        }
      });
    } catch (e) {
      _showError(e);
    }
  }

  Future<void> _toggleRepost(Post post) async {
    if (!_loggedIn) {
      _showLoginPrompt();
      return;
    }
    final bool reposted = post.repostedByMe;
    try {
      if (reposted) {
        await widget.adapter.unrepost(post);
      } else {
        await widget.adapter.repost(post);
      }
      if (!mounted) return;
      setState(() {
        final int index = _posts.indexOf(post);
        if (index >= 0) {
          _posts[index] = post.copyWith(repostedByMe: !reposted);
        }
      });
    } catch (e) {
      _showError(e);
    }
  }

  Future<void> _openDetail(Post post) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            PostDetailScreen(post: post, adapter: widget.adapter),
      ),
    );
    if (mounted) _load();
  }

  Future<void> _openCompose() async {
    final bool? posted = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => ComposeScreen(
          adapters: <PlatformAdapter>[widget.adapter],
          preselected: widget.adapter.id,
        ),
      ),
    );
    if (posted == true && mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final PlatformAdapter adapter = widget.adapter;
    final Set<AdapterCapability> caps = adapter.capabilities;
    final bool needsLogin = adapter.requiresLogin && !_loggedIn;
    return Scaffold(
      appBar: AppBar(
        title: Text(adapter.displayName),
        actions: <Widget>[
          if (_loggedIn)
            TextButton.icon(
              onPressed: _logout,
              icon: const Icon(Icons.logout),
              label: Text(l10n.logout),
            )
          else
            FilledButton.icon(
              onPressed: _openLogin,
              icon: const Icon(Icons.login),
              label: Text(l10n.login),
            ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: _loading
            ? ListView(
                children: const <Widget>[
                  SizedBox(height: 120),
                  Center(child: CircularProgressIndicator()),
                ],
              )
            : needsLogin
                ? ListView(
                    children: <Widget>[
                      const SizedBox(height: 80),
                      Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            const Icon(Icons.lock_outline, size: 48),
                            const SizedBox(height: 16),
                            Text(
                              adapter.id == 'threads'
                                  ? l10n.threadsLoginRequired
                                  : adapter.id == 'telegram'
                                      ? l10n.telegramLoginRequired
                                      : l10n.loginRequired,
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 16),
                            FilledButton.icon(
                              onPressed: _openLogin,
                              icon: const Icon(Icons.login),
                              label: Text(l10n.login),
                            ),
                          ],
                        ),
                      ),
                    ],
                  )
                : _error != null
                    ? ListView(
                        children: <Widget>[
                          const SizedBox(height: 80),
                          Padding(
                            padding: const EdgeInsets.all(24),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: <Widget>[
                                const Icon(Icons.cloud_off, size: 48),
                                const SizedBox(height: 16),
                                Text(_error.toString()),
                                const SizedBox(height: 16),
                                FilledButton(
                                  onPressed: _load,
                                  child: Text(l10n.retry),
                                ),
                              ],
                            ),
                          ),
                        ],
                      )
                    : _posts.isEmpty
                        ? ListView(
                            children: <Widget>[
                              const SizedBox(height: 80),
                              Center(
                                child: Text(l10n.timelineEmpty),
                              ),
                            ],
                          )
                        : ListView.separated(
                            itemCount: _posts.length,
                            separatorBuilder: (_, _) =>
                                const Divider(height: 1),
                            itemBuilder: (BuildContext context, int index) {
                              final Post post = _posts[index];
                              return PostCard(
                                post: post,
                                platformName: adapter.displayName,
                                showPlatform: false,
                                onTap: () => _openDetail(post),
                                onLike: caps.contains(AdapterCapability.like)
                                    ? () => _toggleLike(post)
                                    : null,
                                onRepost:
                                    caps.contains(AdapterCapability.repost)
                                        ? () => _toggleRepost(post)
                                        : null,
                                onReply:
                                    caps.contains(AdapterCapability.comment)
                                        ? () => _openDetail(post)
                                        : null,
                              );
                            },
                          ),
      ),
      floatingActionButton:
          _loggedIn && caps.contains(AdapterCapability.post)
              ? FloatingActionButton(
                  onPressed: _openCompose,
                  tooltip: l10n.post,
                  child: const Icon(Icons.edit),
                )
              : null,
    );
  }
}
