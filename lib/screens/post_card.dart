import 'package:material_ui/material_ui.dart';

import '../core/app_localizations.dart';
import '../core/platform_adapter.dart';

/// One post in a timeline, shared by the unified timeline, the
/// platform screen and the post detail header.
///
/// The card is deliberately dumb: it shows the post and forwards
/// taps to the callbacks the parent provides. A null callback hides
/// that action (the platform does not support it); the parent owns
/// the login check and shows the "log in to interact" message when
/// the user is logged out.
class PostCard extends StatelessWidget {
  const PostCard({
    super.key,
    required this.post,
    required this.platformName,
    this.onTap,
    this.onLike,
    this.onRepost,
    this.onReply,
    this.showPlatform = true,
  });

  final Post post;
  final String platformName;
  final VoidCallback? onTap;
  final VoidCallback? onLike;
  final VoidCallback? onRepost;
  final VoidCallback? onReply;

  /// Whether to show the platform chip (off in a single-platform
  /// screen, where every card is the same platform).
  final bool showPlatform;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final ThemeData theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                CircleAvatar(
                  child: Text(
                    post.authorName.isEmpty
                        ? '?'
                        : post.authorName[0].toUpperCase(),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Row(
                        children: <Widget>[
                          Flexible(
                            child: Text(
                              post.authorName,
                              style: theme.textTheme.titleMedium,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Flexible(
                            child: Text(
                              post.authorHandle,
                              style: theme.textTheme.bodySmall,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                      Text(
                        l10n.relativeTime(post.createdAt),
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                if (showPlatform)
                  Chip(
                    label: Text(platformName),
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Text(post.text, style: theme.textTheme.bodyLarge),
            const SizedBox(height: 8),
            Row(
              children: <Widget>[
                if (onReply != null)
                  _ActionButton(
                    icon: Icons.comment_outlined,
                    label: post.replyCount.toString(),
                    tooltip: l10n.reply,
                    onPressed: onReply,
                  ),
                if (onRepost != null)
                  _ActionButton(
                    icon: post.repostedByMe
                        ? Icons.repeat
                        : Icons.repeat_outlined,
                    label: post.repostCount.toString(),
                    tooltip: post.repostedByMe ? l10n.unrepost : l10n.repost,
                    active: post.repostedByMe,
                    onPressed: onRepost,
                  ),
                if (onLike != null)
                  _ActionButton(
                    icon: post.likedByMe
                        ? Icons.favorite
                        : Icons.favorite_border,
                    label: post.likeCount.toString(),
                    tooltip: post.likedByMe ? l10n.unlike : l10n.like,
                    active: post.likedByMe,
                    onPressed: onLike,
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.icon,
    required this.label,
    required this.tooltip,
    required this.onPressed,
    this.active = false,
  });

  final IconData icon;
  final String label;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final Color color = active
        ? Theme.of(context).colorScheme.primary
        : Theme.of(context).colorScheme.onSurfaceVariant;
    return TextButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 18, color: color),
      label: Text(label, style: TextStyle(color: color)),
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        minimumSize: const Size(0, 36),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    );
  }
}
