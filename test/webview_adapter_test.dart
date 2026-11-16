// WebView fallback adapter tests.
//
// No real WebView, network or account is involved: the URL routing and
// login-state detection are pure Dart (lib/adapters/webview/) and the
// adapter is exercised with an in-memory account store and a fake
// cookie clearer. The screen itself needs a real WebView, so it is
// covered by `flutter analyze` only — see
// lib/screens/platform_webview_screen.dart.

import 'package:flutter_test/flutter_test.dart';
import 'package:similar_x/adapters/registry.dart';
import 'package:similar_x/adapters/webview/webview_session.dart';
import 'package:similar_x/adapters/webview_adapter.dart';
import 'package:similar_x/core/account_store.dart';
import 'package:similar_x/core/platform_adapter.dart';

/// In-memory account store: the real one wraps flutter_secure_storage,
/// which has no platform channel in tests.
class FakeAccountStore extends AccountStore {
  final Map<String, String> values = <String, String>{};

  @override
  Future<void> saveToken(String platformId, String token) async {
    values['similar_x_token_$platformId'] = token;
  }

  @override
  Future<String?> readToken(String platformId) async =>
      values['similar_x_token_$platformId'];

  @override
  Future<void> deleteToken(String platformId) async {
    values.remove('similar_x_token_$platformId');
  }

  @override
  Future<void> saveValue(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<String?> readValue(String key) async => values[key];

  @override
  Future<void> deleteValue(String key) async {
    values.remove(key);
  }
}

void main() {
  group('URL routing', () {
    test('X allows its own hosts and blocks everything else', () {
      expect(xWebViewConfig.isAllowedUrl(Uri.parse('https://x.com/')),
          isTrue);
      expect(
          xWebViewConfig.isAllowedUrl(
              Uri.parse('https://mobile.x.com/home')),
          isTrue);
      // twitter.com still redirects to x.com.
      expect(
          xWebViewConfig.isAllowedUrl(Uri.parse('https://twitter.com/')),
          isTrue);
      expect(
          xWebViewConfig.isAllowedUrl(Uri.parse('https://example.com/')),
          isFalse);
      expect(
          xWebViewConfig.isAllowedUrl(
              Uri.parse('https://evil-x.com/login')),
          isFalse);
      expect(
          xWebViewConfig.isAllowedUrl(Uri.parse('ftp://x.com/')), isFalse);
    });

    test('Instagram allows instagram.com hosts only', () {
      expect(
          instagramWebViewConfig.isAllowedUrl(
              Uri.parse('https://www.instagram.com/')),
          isTrue);
      expect(
          instagramWebViewConfig.isAllowedUrl(
              Uri.parse('https://instagram.com/someuser/')),
          isTrue);
      expect(
          instagramWebViewConfig.isAllowedUrl(
              Uri.parse('https://www.facebook.com/')),
          isFalse);
    });

    test('Facebook allows facebook.com hosts only', () {
      expect(
          facebookWebViewConfig.isAllowedUrl(
              Uri.parse('https://m.facebook.com/')),
          isTrue);
      expect(
          facebookWebViewConfig.isAllowedUrl(
              Uri.parse('https://www.facebook.com/')),
          isTrue);
      expect(
          facebookWebViewConfig.isAllowedUrl(
              Uri.parse('https://www.instagram.com/')),
          isFalse);
    });
  });

  group('login-state detection from URLs', () {
    test('X: login flow pages are guest, home/messages are logged in',
        () {
      final WebViewPlatformConfig config = xWebViewConfig;
      expect(
          config.detectLoginState(Uri.parse('https://x.com/i/flow/login')),
          WebViewLoginState.guest);
      expect(
          config.detectLoginState(Uri.parse('https://x.com/i/flow/signup')),
          WebViewLoginState.guest);
      expect(config.detectLoginState(Uri.parse('https://x.com/home')),
          WebViewLoginState.loggedIn);
      expect(
          config.detectLoginState(Uri.parse('https://x.com/notifications')),
          WebViewLoginState.loggedIn);
      expect(config.detectLoginState(Uri.parse('https://x.com/messages')),
          WebViewLoginState.loggedIn);
      expect(
          config.detectLoginState(Uri.parse('https://x.com/i/bookmarks')),
          WebViewLoginState.loggedIn);
      // Public pages say nothing either way.
      expect(config.detectLoginState(Uri.parse('https://x.com/explore')),
          WebViewLoginState.unknown);
      expect(config.detectLoginState(Uri.parse('https://x.com/someuser')),
          WebViewLoginState.unknown);
      expect(
          config.detectLoginState(
              Uri.parse('https://x.com/someuser/status/123')),
          WebViewLoginState.unknown);
      expect(config.detectLoginState(Uri.parse('https://x.com/')),
          WebViewLoginState.unknown);
      // A login page never counts as logged in, even under a
      // logged-in-only prefix.
      expect(
          config.detectLoginState(
              Uri.parse('https://x.com/i/flow/login?x=1')),
          WebViewLoginState.guest);
    });

    test('Instagram: login page is guest, home/direct are logged in', () {
      final WebViewPlatformConfig config = instagramWebViewConfig;
      expect(
          config.detectLoginState(
              Uri.parse('https://www.instagram.com/accounts/login/')),
          WebViewLoginState.guest);
      expect(
          config.detectLoginState(Uri.parse(
              'https://www.instagram.com/accounts/emailsignup/')),
          WebViewLoginState.guest);
      // Instagram redirects logged-out visitors away from `/`, so
      // landing on the bare home URL means logged in.
      expect(
          config.detectLoginState(Uri.parse('https://www.instagram.com/')),
          WebViewLoginState.loggedIn);
      expect(
          config.detectLoginState(
              Uri.parse('https://www.instagram.com/direct/inbox/')),
          WebViewLoginState.loggedIn);
      expect(
          config.detectLoginState(
              Uri.parse('https://www.instagram.com/someuser/')),
          WebViewLoginState.unknown);
      expect(
          config.detectLoginState(
              Uri.parse('https://www.instagram.com/p/ABC123/')),
          WebViewLoginState.unknown);
      expect(
          config.detectLoginState(
              Uri.parse('https://www.instagram.com/explore/')),
          WebViewLoginState.unknown);
    });

    test('Facebook: login pages are guest, profile/messages logged in',
        () {
      final WebViewPlatformConfig config = facebookWebViewConfig;
      expect(
          config.detectLoginState(Uri.parse('https://m.facebook.com/login/')),
          WebViewLoginState.guest);
      expect(
          config.detectLoginState(
              Uri.parse('https://m.facebook.com/login.php')),
          WebViewLoginState.guest);
      expect(
          config.detectLoginState(
              Uri.parse('https://m.facebook.com/profile.php?id=1')),
          WebViewLoginState.loggedIn);
      expect(
          config.detectLoginState(Uri.parse('https://m.facebook.com/messages/')),
          WebViewLoginState.loggedIn);
      expect(
          config.detectLoginState(
              Uri.parse('https://m.facebook.com/notifications/')),
          WebViewLoginState.loggedIn);
      // The mobile home URL shows a login form to guests and a feed
      // to logged-in users, so the URL alone cannot tell.
      expect(config.detectLoginState(Uri.parse('https://m.facebook.com/')),
          WebViewLoginState.unknown);
      expect(
          config.detectLoginState(
              Uri.parse('https://m.facebook.com/somepage/')),
          WebViewLoginState.unknown);
    });

    test('prefix matching does not over-match', () {
      // `/home` must not match `/homepage`.
      expect(
          xWebViewConfig.detectLoginState(Uri.parse('https://x.com/homepage')),
          WebViewLoginState.unknown);
      // `/login` must not match `/loginpage`.
      expect(
          facebookWebViewConfig
              .detectLoginState(Uri.parse('https://m.facebook.com/loginpage')),
          WebViewLoginState.unknown);
    });
  });

  group('WebViewAdapter', () {
    late FakeAccountStore store;
    late int cookieClears;
    late WebViewAdapter adapter;

    setUp(() {
      store = FakeAccountStore();
      cookieClears = 0;
      adapter = WebViewAdapter(
        config: xWebViewConfig,
        accountStore: store,
        cookieClearer: () async {
          cookieClears++;
        },
      );
    });

    test('declares the webview status with no native capabilities', () {
      expect(adapter.id, 'webview_x');
      expect(adapter.displayName, 'X');
      expect(adapter.status, PlatformStatus.webview);
      expect(adapter.capabilities, isEmpty);
      expect(adapter.requiresLogin, isFalse);
      expect(adapter.note, isNotEmpty);
      expect(adapter.note, contains('no API'));
      expect(adapter.note, contains('no token'));
    });

    test('the unified timeline is always empty — no native feed', () async {
      expect(await adapter.fetchTimeline(), isEmpty);
      expect(await adapter.fetchTimeline(limit: 5), isEmpty);
    });

    test('login() throws: login happens inside the WebView', () async {
      await expectLater(adapter.login(),
          throwsA(isA<WebViewLoginException>()));
    });

    test('login state is a stored hint, not a token', () async {
      expect(await adapter.isLoggedIn, isFalse);
      // No token is ever written for a WebView platform.
      expect(store.values.keys.where(
          (String k) => k.startsWith('similar_x_token_')), isEmpty);

      await adapter.markLoggedIn();
      expect(await adapter.isLoggedIn, isTrue);
      // Still no token — only the `1` hint flag.
      expect(store.values.keys.where(
          (String k) => k.startsWith('similar_x_token_')), isEmpty);

      await adapter.markLoggedOut();
      expect(await adapter.isLoggedIn, isFalse);
    });

    test('logout clears the hint and the WebView cookies', () async {
      await adapter.markLoggedIn();
      expect(await adapter.isLoggedIn, isTrue);
      await adapter.logout();
      expect(await adapter.isLoggedIn, isFalse);
      expect(cookieClears, 1);
    });
  });

  group('registry', () {
    test('X, Instagram and Facebook are registered as WebView adapters',
        () async {
      final List<PlatformAdapter> adapters = buildAdapterRegistry();
      final Map<String, PlatformAdapter> byId = <String, PlatformAdapter>{
        for (final PlatformAdapter a in adapters) a.id: a,
      };
      for (final String id in <String>[
        'webview_x',
        'webview_instagram',
        'webview_facebook',
      ]) {
        final PlatformAdapter? adapter = byId[id];
        expect(adapter, isNotNull, reason: '$id must be registered');
        expect(adapter!.status, PlatformStatus.webview);
        expect(adapter.requiresLogin, isFalse);
        expect(adapter.capabilities, isEmpty);
        expect(await adapter.fetchTimeline(), isEmpty);
        expect(await adapter.isLoggedIn, isFalse);
      }
      final WebViewAdapter x = byId['webview_x']! as WebViewAdapter;
      expect(x.config.homeUrl.toString(), 'https://x.com/');
      final WebViewAdapter instagram =
          byId['webview_instagram']! as WebViewAdapter;
      expect(instagram.config.homeUrl.toString(),
          'https://www.instagram.com/');
      final WebViewAdapter facebook =
          byId['webview_facebook']! as WebViewAdapter;
      expect(facebook.config.homeUrl.toString(), 'https://m.facebook.com/');
    });
  });
}
