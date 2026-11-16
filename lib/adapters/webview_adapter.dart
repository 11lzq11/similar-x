import 'package:material_ui/material_ui.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../core/account_store.dart';
import '../core/platform_adapter.dart';
import '../screens/platform_webview_screen.dart';
import 'webview/webview_session.dart';

/// Thrown by [WebViewAdapter.login]: login happens inside the WebView,
/// never through an API. Open the platform with [WebViewAdapter.openWebView]
/// and log in on the platform's own page.
class WebViewLoginException implements Exception {
  const WebViewLoginException(this.message);

  final String message;

  @override
  String toString() => 'WebViewLoginException: $message';
}

/// Clears the WebView's cookies (signs the user out of the platform
/// inside the WebView). Injectable so tests can fake it.
typedef WebViewCookieClearer = Future<void> Function();

Future<void> _defaultCookieClearer() async {
  try {
    await WebViewCookieManager().clearCookies();
  } catch (_) {
    // Best effort: on platforms without a WebView (Windows/Linux in
    // v0.1.0) there is nothing to clear.
  }
}

/// WebView fallback for one closed platform (X, Instagram, Facebook).
///
/// These platforms have no usable API for a personal timeline: X is
/// pay-per-read and its developer agreement forbids replacement
/// clients; Instagram's Basic Display API closed in 2024 and only
/// business accounts have any API; Facebook's Graph API covers Pages
/// only. The only compliant shape is embedding the official mobile
/// web: the login stays inside the WebView and no user token is ever
/// touched. Timeline, likes and comments happen through the website,
/// so the unified timeline cannot pull this platform's posts natively
/// — [fetchTimeline] always returns an empty list. Experience is close
/// to the mobile website, with no push notifications.
///
/// Session model (read this before touching it):
/// * the session lives in the WebView's cookies, never in
///   [AccountStore] — there is no token to store;
/// * [isLoggedIn] only reports a login-state *hint* observed from the
///   WebView's URL (see [markLoggedIn]/[markLoggedOut]), persisted as
///   a plain `1` flag in encrypted storage. It is not a credential.
///
/// Desktop caveat: `webview_flutter` officially supports Android,
/// iOS and macOS. On Windows/Linux a WebView needs a community plugin
/// (e.g. webview_windows / webview_linux) — that is future work; until
/// then the screen reports WebView as unavailable on desktop.
class WebViewAdapter extends PlatformAdapter {
  WebViewAdapter({
    required this.config,
    AccountStore? accountStore,
    WebViewCookieClearer? cookieClearer,
  })  : _accountStore = accountStore ?? AccountStore(),
        _cookieClearer = cookieClearer ?? _defaultCookieClearer;

  /// The platform's WebView configuration (URLs, hosts, login rules).
  final WebViewPlatformConfig config;

  final AccountStore _accountStore;
  final WebViewCookieClearer _cookieClearer;

  String get _loginFlagKey => 'webview_${config.platformId}_logged_in';

  @override
  String get id => 'webview_${config.platformId}';

  @override
  String get displayName => config.displayName;

  @override
  PlatformStatus get status => PlatformStatus.webview;

  @override
  Set<AdapterCapability> get capabilities => const <AdapterCapability>{};

  @override
  String get note =>
      'WebView only — no API, no native feed. The official mobile web '
      '(${config.homeUrl.host}) runs inside the app; timeline, likes and '
      'comments work through the website. Login stays in the WebView; no '
      'token is ever stored. WebView is not available on Windows/Linux yet.';

  @override
  bool get requiresLogin => false;

  /// Whether the user is logged in inside the WebView, as last observed
  /// from the WebView's URL. A hint only — the session lives in the
  /// WebView's cookies.
  @override
  Future<bool> get isLoggedIn async {
    try {
      return await _accountStore.readValue(_loginFlagKey) == '1';
    } catch (_) {
      return false;
    }
  }

  /// Records that the WebView just showed a logged-in-only page.
  Future<void> markLoggedIn() async {
    try {
      await _accountStore.saveValue(_loginFlagKey, '1');
    } catch (_) {
      // Best effort only.
    }
  }

  /// Records that the WebView just showed a login page.
  Future<void> markLoggedOut() async {
    try {
      await _accountStore.deleteValue(_loginFlagKey);
    } catch (_) {
      // Best effort only.
    }
  }

  /// The unified timeline cannot include this platform: there is no
  /// API to read posts. Open the platform in the WebView instead.
  @override
  Future<List<Post>> fetchTimeline({int limit = 20}) async =>
      const <Post>[];

  /// Login happens inside the WebView — call [openWebView] and log in
  /// on the platform's own page. There is no API login to run here.
  @override
  Future<void> login() async {
    throw WebViewLoginException(
      'Log in inside the WebView on ${config.displayName} — '
      'there is no API login for this platform.',
    );
  }

  /// Logs out: clears the login hint and the WebView's cookies, so the
  /// next WebView visit starts as a guest.
  @override
  Future<void> logout() async {
    await markLoggedOut();
    try {
      await _cookieClearer();
    } catch (_) {
      // Best effort only.
    }
  }

  /// Opens the platform's mobile web in the in-app WebView screen.
  Future<void> openWebView(BuildContext context) {
    return Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PlatformWebViewScreen(adapter: this),
      ),
    );
  }
}
