// Similar-X v0.1.0 tests: adapter registry invariants + app smoke test.

import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:similar_x/adapters/registry.dart';
import 'package:similar_x/core/app_state.dart';
import 'package:similar_x/core/platform_adapter.dart';
import 'package:similar_x/main.dart';

import 'fake_adapter.dart';

void main() {
  test('adapter registry has unique ids and names', () {
    final List<PlatformAdapter> adapters = buildAdapterRegistry();
    expect(adapters, isNotEmpty);
    final Set<String> ids = adapters.map((a) => a.id).toSet();
    expect(ids.length, adapters.length, reason: 'adapter ids must be unique');
    for (final PlatformAdapter adapter in adapters) {
      expect(adapter.displayName, isNotEmpty);
      expect(adapter.id, isNotEmpty);
    }
  });

  test('implemented adapters report their real status', () async {
    for (final PlatformAdapter adapter in buildAdapterRegistry()) {
      switch (adapter.id) {
        case 'telegram':
          // Telegram is implemented (TDLib); it is limited, not planned.
          // Logged out it still behaves like a guest: empty timeline.
          expect(adapter.status, PlatformStatus.limited);
          expect(await adapter.fetchTimeline(), isEmpty);
          expect(await adapter.isLoggedIn, isFalse);
        case 'mastodon':
          // Mastodon is implemented (REST). Guests get the public
          // timeline, which needs the network, so it is not fetched
          // here — see mastodon_adapter_test.dart.
          expect(adapter.status, PlatformStatus.ready);
          expect(adapter.requiresLogin, isFalse);
          expect(await adapter.isLoggedIn, isFalse);
        case 'bluesky':
          // Bluesky is implemented (AT Protocol). Guests get the
          // Discover feed, which needs the network, so it is not
          // fetched here — see bluesky_adapter_test.dart.
          expect(adapter.status, PlatformStatus.ready);
          expect(adapter.requiresLogin, isFalse);
          expect(await adapter.isLoggedIn, isFalse);
        case 'youtube':
          // YouTube is implemented (Data API v3) but limited by
          // quota. Guests get the most popular chart and search
          // needs an API key, so the timeline is not fetched
          // here — see youtube_adapter_test.dart.
          expect(adapter.status, PlatformStatus.limited);
          expect(adapter.requiresLogin, isFalse);
          expect(await adapter.isLoggedIn, isFalse);
        case 'reddit':
          // Reddit is implemented (Data API OAuth) but limited
          // by the free tier and the manual-approval gate.
          // Guests get r/popular, which needs the network, so
          // the timeline is not fetched here — see
          // reddit_adapter_test.dart.
          expect(adapter.status, PlatformStatus.limited);
          expect(adapter.requiresLogin, isFalse);
          expect(await adapter.isLoggedIn, isFalse);
        case 'threads':
          // Threads is implemented (Threads API) but limited
          // to the account's own content and requires login.
          // Guests get an empty timeline, never fake data —
          // see threads_adapter_test.dart.
          expect(adapter.status, PlatformStatus.limited);
          expect(adapter.requiresLogin, isTrue);
          expect(await adapter.fetchTimeline(), isEmpty);
          expect(await adapter.isLoggedIn, isFalse);
        case 'webview_x':
        case 'webview_instagram':
        case 'webview_facebook':
          // WebView fallback: the official mobile web runs in-app,
          // login stays in the WebView, no native feed — see
          // webview_adapter_test.dart.
          expect(adapter.status, PlatformStatus.webview);
          expect(adapter.requiresLogin, isFalse);
          expect(adapter.capabilities, isEmpty);
          expect(await adapter.fetchTimeline(), isEmpty);
          expect(await adapter.isLoggedIn, isFalse);
        default:
          expect(adapter.status, PlatformStatus.planned);
          expect(await adapter.fetchTimeline(), isEmpty);
          expect(await adapter.isLoggedIn, isFalse);
      }
    }
  });

  testWidgets('app renders the timeline tab and the platform list',
      (WidgetTester tester) async {
    // Fake adapters: the real registry would do network I/O on the
    // timeline tab (guest feeds), which a smoke test must not need.
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>(
        create: (_) => AppState(adapters: <PlatformAdapter>[
          FakeAdapter(id: 'fake_a', displayName: 'Telegram'),
          FakeAdapter(id: 'fake_b', displayName: 'Mastodon'),
          FakeAdapter(id: 'fake_c', displayName: 'Bluesky'),
        ]),
        child: const SimilarXApp(),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Similar-X'), findsWidgets);
    expect(find.text('Timeline'), findsOneWidget);
    expect(find.text('No posts yet — pull to refresh.'), findsOneWidget);
    // The platform list lives on the second tab.
    await tester.tap(find.text('Platforms'));
    await tester.pumpAndSettle();
    expect(find.text('Telegram'), findsOneWidget);
    expect(find.text('Mastodon'), findsOneWidget);
    expect(find.text('Bluesky'), findsOneWidget);
  });
}
