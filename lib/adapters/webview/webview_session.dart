/// Pure-Dart logic for the WebView fallback adapters (X, Instagram,
/// Facebook). No Flutter or WebView dependency here, so it is fully
/// unit-testable without a real WebView.
///
/// These platforms have no usable official API for a personal
/// timeline, so Similar-X embeds their official mobile web instead.
/// The login lives in the WebView's cookies; Similar-X never sees a
/// token. Login state is therefore read from the WebView's current
/// URL only — a heuristic, not a session check:
/// * a login page means the user is definitely logged out;
/// * a page only a logged-in user can see (home feed, messages,
///   notifications) means the user is definitely logged in;
/// * a public page (profile, post, explore) says nothing either way.
library;

/// Login state as read from the WebView's current URL.
enum WebViewLoginState {
  /// The URL is a login page: the user is definitely logged out.
  guest,

  /// The URL is a page only a logged-in user can see.
  loggedIn,

  /// A public page (profile, post, explore): the URL alone cannot tell.
  unknown,
}

/// Configuration for one closed platform's embedded mobile web.
class WebViewPlatformConfig {
  const WebViewPlatformConfig({
    required this.platformId,
    required this.displayName,
    required this.homeUrl,
    required this.loginUrl,
    required this.logoutUrl,
    required this.allowedHosts,
    required this.loginPagePaths,
    required this.loggedInOnlyPaths,
  });

  /// Stable id, e.g. `x`. The adapter id is `webview_<platformId>`.
  final String platformId;

  /// Human-readable name, e.g. `X`.
  final String displayName;

  /// Where the WebView opens. Guests see the platform's landing /
  /// login wall; logged-in users see their feed.
  final Uri homeUrl;

  /// The platform's login page.
  final Uri loginUrl;

  /// The platform's logout URL (navigating there signs the WebView out).
  final Uri logoutUrl;

  /// Hosts the WebView may navigate to. Anything else is an external
  /// link and is blocked inside the WebView.
  final Set<String> allowedHosts;

  /// URL path patterns that prove the user is logged out. A pattern
  /// matches a path exactly or as a path prefix (`/home` matches
  /// `/home` and `/home/...`, but not `/homepage`).
  final List<String> loginPagePaths;

  /// URL path patterns that prove the user is logged in. Checked only
  /// after [loginPagePaths], so a login page never counts as logged in.
  final List<String> loggedInOnlyPaths;

  /// Whether this URL may load inside the WebView: http(s) on one of
  /// the platform's own hosts.
  bool isAllowedUrl(Uri url) =>
      (url.scheme == 'https' || url.scheme == 'http') &&
      allowedHosts.contains(url.host.toLowerCase());

  /// Whether this URL is one of the platform's login pages.
  bool isLoginPage(Uri url) => _matchesAny(url.path, loginPagePaths);

  /// Whether this URL is a page only a logged-in user can see.
  bool isLoggedInOnlyPage(Uri url) =>
      _matchesAny(url.path, loggedInOnlyPaths);

  /// The login state this URL implies.
  WebViewLoginState detectLoginState(Uri url) {
    if (isLoginPage(url)) return WebViewLoginState.guest;
    if (isLoggedInOnlyPage(url)) return WebViewLoginState.loggedIn;
    return WebViewLoginState.unknown;
  }

  static bool _matchesAny(String path, List<String> patterns) {
    final String p = path.toLowerCase();
    for (final String pattern in patterns) {
      final String q = pattern.toLowerCase();
      if (p == q || p.startsWith('$q/')) return true;
    }
    return false;
  }
}

/// X — no usable API for a personal timeline: the official API is
/// pay-per-read and the developer agreement forbids replacement
/// clients. The mobile web is the only compliant shape.
final WebViewPlatformConfig xWebViewConfig = WebViewPlatformConfig(
  platformId: 'x',
  displayName: 'X',
  homeUrl: Uri.parse('https://x.com/'),
  loginUrl: Uri.parse('https://x.com/i/flow/login'),
  logoutUrl: Uri.parse('https://x.com/logout'),
  // twitter.com still redirects to x.com; allow it so the redirect
  // is not blocked as an external link.
  allowedHosts: <String>{
    'x.com',
    'mobile.x.com',
    'twitter.com',
    'mobile.twitter.com',
  },
  loginPagePaths: <String>['/i/flow/login', '/i/flow/signup'],
  loggedInOnlyPaths: <String>[
    '/home',
    '/notifications',
    '/messages',
    '/i/bookmarks',
    '/i/lists',
    '/settings',
    '/compose',
  ],
);

/// Instagram — the Basic Display API closed in December 2024 and only
/// business/creator accounts have any API left. Personal accounts get
/// the mobile web only.
final WebViewPlatformConfig instagramWebViewConfig =
    WebViewPlatformConfig(
  platformId: 'instagram',
  displayName: 'Instagram',
  homeUrl: Uri.parse('https://www.instagram.com/'),
  loginUrl: Uri.parse('https://www.instagram.com/accounts/login/'),
  logoutUrl: Uri.parse('https://www.instagram.com/accounts/logout/'),
  allowedHosts: <String>{'www.instagram.com', 'instagram.com'},
  loginPagePaths: <String>[
    '/accounts/login',
    '/accounts/emailsignup',
    '/accounts/password/reset',
  ],
  // Instagram redirects logged-out visitors away from `/`, so landing
  // on the bare home URL means the user is logged in.
  loggedInOnlyPaths: <String>['/', '/direct'],
);

/// Facebook — the Graph API covers Pages only; a personal feed has no
/// API. The mobile web is the only shape for a personal account.
final WebViewPlatformConfig facebookWebViewConfig =
    WebViewPlatformConfig(
  platformId: 'facebook',
  displayName: 'Facebook',
  homeUrl: Uri.parse('https://m.facebook.com/'),
  loginUrl: Uri.parse('https://m.facebook.com/login/'),
  logoutUrl: Uri.parse('https://m.facebook.com/logout.php'),
  allowedHosts: <String>{
    'm.facebook.com',
    'www.facebook.com',
    'facebook.com',
  },
  loginPagePaths: <String>['/login', '/login.php', '/recover'],
  loggedInOnlyPaths: <String>[
    '/home.php',
    '/profile.php',
    '/messages',
    '/notifications',
    '/groups',
    '/events',
    '/saved',
    '/settings',
  ],
);
