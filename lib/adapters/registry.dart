import '../core/platform_adapter.dart';
import 'bluesky_adapter.dart';
import 'mastodon_adapter.dart';
import 'reddit_adapter.dart';
import 'telegram_adapter.dart';
import 'threads_adapter.dart';
import 'webview_adapter.dart';
import 'youtube_adapter.dart';

/// The full adapter set, in launch-priority order (see
/// research/third-party-feasibility.md).
///
/// Tier 1 — fully working on official, free APIs: Telegram, Mastodon,
/// Bluesky. Tier 2 — limited: YouTube, Reddit, Threads. Tier 3 —
/// WebView fallback only: X, Instagram, Facebook. Discord and TikTok
/// are deliberately not registered in v0.1.0 (Discord forbids user
/// tokens; TikTok has no public feed API).
///
/// Adapters are cheap to construct and do no I/O until used, so the
/// registry is a plain list for now. Lazy loading per adapter lands
/// with the first real API client. The list is not const: adapters
/// with real clients (Telegram) hold runtime dependencies.
List<PlatformAdapter> buildAdapterRegistry() => <PlatformAdapter>[
      TelegramAdapter(),
      MastodonAdapter(),
      BlueskyAdapter(),
      YouTubeAdapter(),
      RedditAdapter(),
      ThreadsAdapter(),
      WebViewAdapter(
        platformId: 'x',
        platformName: 'X',
        mobileWebUrl: 'https://x.com/',
      ),
      WebViewAdapter(
        platformId: 'instagram',
        platformName: 'Instagram',
        mobileWebUrl: 'https://www.instagram.com/',
      ),
      WebViewAdapter(
        platformId: 'facebook',
        platformName: 'Facebook',
        mobileWebUrl: 'https://m.facebook.com/',
      ),
    ];
