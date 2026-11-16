import 'package:material_ui/material_ui.dart';

import '../core/app_localizations.dart';
import '../core/platform_adapter.dart';
import 'post_card.dart';

/// One post and its comments, with like / repost / reply actions.
///
/// Actions are only offered when the adapter declares the
/// capability; when logged out they show the login prompt instead
/// of calling the API. For Telegram the post is a chat and the
/// comments are its messages, so the reply box sends a message.
class PostDetailScreen extends StatefulWidget {
  const PostDetailScreen({
    super.key,
    required this.post,
    required this.adapter,
  });

  final Post post;
  final PlatformAdapter adapter;

  @override
  State<PostDetailScreen> createState() => _PostDetailScreenState();
}

class _PostDetailScreenState extends State<PostDetailScreen> {
  final TextEditingController _replyController = TextEditingController();
  final FocusNode _replyFocus = FocusNode();
  late Post _post;
  List<Post> _comments = <Post>[];
  bool _loadingComments = true;
  bool _loggedIn = false;
  Object? _commentsError;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _post = widget.post;
    _load();
  }

  @override
  void dispose() {
    _replyController.dispose();
    _replyFocus.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    bool loggedIn = false;
    try {
      loggedIn = await widget.adapter.isLoggedIn;
    } catch (_) {
      loggedIn = false;
    }
    List<Post> comments = <Post>[];
    Object? error;
    if (widget.adapter.capabilities.contains(AdapterCapability.comment)) {
      try {
        comments = await widget.adapter.fetchComments(widget.post);
      } catch (e) {
        error = e;
      }
    }
    if (!mounted) return;
    setState(() {
      _loggedIn = loggedIn;
      _comments = comments;
      _commentsError = error;
      _loadingComments = false;
    });
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
        _post = _updatePost(_post, post, likedByMe: !liked);
        _comments = _comments
            .map(
              (Post c) => c.id == post.id
                  ? c.copyWith(likedByMe: !liked)
                  : c,
            )
            .toList();
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
        _post = _updatePost(_post, post, repostedByMe: !reposted);
        _comments = _comments
            .map(
              (Post c) => c.id == post.id
                  ? c.copyWith(repostedByMe: !reposted)
                  : c,
            )
            .toList();
      });
    } catch (e) {
      _showError(e);
    }
  }

  /// Applies a like/repost flip to the header post when the acted-on
  /// post is the header, otherwise leaves it unchanged.
  Post _updatePost(
    Post header,
    Post actedOn, {
    bool? likedByMe,
    bool? repostedByMe,
  }) {
    if (header.id != actedOn.id) return header;
    return header.copyWith(
      likedByMe: likedByMe,
      repostedByMe: repostedByMe,
    );
  }

  Future<void> _sendReply() async {
    final String text = _replyController.text.trim();
    if (text.isEmpty || _sending) return;
    if (!_loggedIn) {
      _showLoginPrompt();
      return;
    }
    setState(() => _sending = true);
    try {
      await widget.adapter.commentOn(widget.post, text);
      if (!mounted) return;
      _replyController.clear();
      _replyFocus.unfocus();
      setState(() => _sending = false);
      await _load();
    } catch (e) {
      if (!mounted) return;
      setState(() => _sending = false);
      _showError(e);
    }
  }

  /// Indentation for a nested reply (Reddit keeps the depth in
  /// [Post.meta]; other platforms are flat).
  double _indentOf(Post comment) {
    final int depth = int.tryParse(comment.meta['depth'] ?? '0') ?? 0;
    return (depth.clamp(0, 6) * 16).toDouble();
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final PlatformAdapter adapter = widget.adapter;
    final Set<AdapterCapability> caps = adapter.capabilities;
    final bool canComment = caps.contains(AdapterCapability.comment);
    final bool isTelegram = adapter.id == 'telegram';
    return Scaffold(
      appBar: AppBar(
        title: Text(
          isTelegram ? _post.authorName : adapter.displayName,
        ),
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          children: <Widget>[
            PostCard(
              post: _post,
              platformName: adapter.displayName,
              onLike: caps.contains(AdapterCapability.like)
                  ? () => _toggleLike(_post)
                  : null,
              onRepost: caps.contains(AdapterCapability.repost)
                  ? () => _toggleRepost(_post)
                  : null,
              onReply: canComment
                  ? () => _replyFocus.requestFocus()
                  : null,
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Text(
                isTelegram ? l10n.chat : l10n.comments,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            if (_loadingComments)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 32),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_commentsError != null)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(_commentsError.toString()),
              )
            else if (_comments.isEmpty)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(l10n.noComments),
              )
            else
              for (final Post comment in _comments)
                Padding(
                  padding: EdgeInsets.only(left: _indentOf(comment)),
                  child: Column(
                    children: <Widget>[
                      PostCard(
                        post: comment,
                        platformName: adapter.displayName,
                        showPlatform: false,
                        onLike: caps.contains(AdapterCapability.like)
                            ? () => _toggleLike(comment)
                            : null,
                        onRepost:
                            caps.contains(AdapterCapability.repost)
                                ? () => _toggleRepost(comment)
                                : null,
                      ),
                      const Divider(height: 1),
                    ],
                  ),
                ),
            const SizedBox(height: 80),
          ],
        ),
      ),
      bottomSheet: canComment
          ? Container(
              padding: EdgeInsets.only(
                left: 12,
                right: 12,
                top: 8,
                bottom: 8 + MediaQuery.of(context).viewInsets.bottom,
              ),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface,
                border: Border(
                  top: BorderSide(color: Theme.of(context).dividerColor),
                ),
              ),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: TextField(
                      controller: _replyController,
                      focusNode: _replyFocus,
                      decoration: InputDecoration(
                        hintText: l10n.replyHint,
                        border: const OutlineInputBorder(),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                      ),
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _sendReply(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: _sending ? null : _sendReply,
                    child: Text(
                      isTelegram ? l10n.sendMessage : l10n.reply,
                    ),
                  ),
                ],
              ),
            )
          : null,
    );
  }
}
