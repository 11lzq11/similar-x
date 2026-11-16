// Similar-X v0.1.0 tests: adapter registry invariants + app smoke test.

import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:similar_x/adapters/registry.dart';
import 'package:similar_x/core/app_state.dart';
import 'package:similar_x/core/platform_adapter.dart';
import 'package:similar_x/main.dart';

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

  test('every registered adapter is a stub for now, except Telegram',
      () async {
    for (final PlatformAdapter adapter in buildAdapterRegistry()) {
      if (adapter.id == 'telegram') {
        // Telegram is implemented (TDLib); it is limited, not planned.
        // Logged out it still behaves like a guest: empty timeline.
        expect(adapter.status, PlatformStatus.limited);
      } else {
        expect(adapter.status, PlatformStatus.planned);
      }
      expect(await adapter.fetchTimeline(), isEmpty);
      expect(await adapter.isLoggedIn, isFalse);
    }
  });

  testWidgets('app renders the platform list', (WidgetTester tester) async {
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>(
        create: (_) => AppState(adapters: buildAdapterRegistry()),
        child: const SimilarXApp(),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Similar-X'), findsWidgets);
    expect(find.text('Telegram'), findsOneWidget);
    expect(find.text('Mastodon'), findsOneWidget);
    expect(find.text('Bluesky'), findsOneWidget);
  });
}
