import '../core/platform_adapter.dart';
import 'stub_adapter.dart';

/// WebView fallback for closed platforms (X, Instagram, Facebook,
/// Discord).
///
/// These platforms have no usable API for a personal timeline: X is
/// pay-per-read and its developer agreement forbids replacement
/// clients; Instagram's Basic Display API closed in 2024 and only
/// business accounts have any API; Facebook's Graph API covers Pages
/// only; Discord forbids user-token automation. The only compliant
/// shape is embedding the official mobile web: the login stays inside
/// the WebView and no user token is ever touched. Experience is close
/// to the mobile website, with no push notifications.
///
/// Desktop caveat: `webview_flutter` officially supports Android,
/// iOS and macOS. On Windows/Linux a WebView needs a community plugin
/// (e.g. webview_windows / webview_linux) — that is future work; until
/// then this adapter reports itself as unavailable on desktop.
class WebViewAdapter extends StubAdapter {
  const WebViewAdapter({
    required this.platformId,
    required this.platformName,
    required this.mobileWebUrl,
  });

  final String platformId;
  final String platformName;
  final String mobileWebUrl;

  @override
  String get id => 'webview_$platformId';

  @override
  String get displayName => platformName;

  @override
  PlatformStatus get status => PlatformStatus.planned;

  @override
  Set<AdapterCapability> get capabilities => const <AdapterCapability>{};

  @override
  String get note =>
      'WebView only — no API; login stays inside the WebView.';
}
