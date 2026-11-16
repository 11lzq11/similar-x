// UI tests for the real screens: unified timeline, platform screen,
// login screen, composer and post detail — all driven by fake
// adapters (and a scripted MockClient for the Bluesky login form),
// so no real account or network is involved.

import 'dart:convert';

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter_localizations/flutter_localizations.dart'
    hide GlobalCupertinoLocalizations, GlobalMaterialLocalizations;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:similar_x/adapters/bluesky/bluesky_client.dart';
import 'package:similar_x/adapters/bluesky_adapter.dart';
import 'package:similar_x/core/app_localizations.dart';
import 'package:similar_x/core/app_state.dart';
import 'package:similar_x/core/platform_adapter.dart';
import 'package:similar_x/main.dart';
import 'package:similar_x/screens/compose_screen.dart';
import 'package:similar_x/screens/login_screen.dart';
import 'package:similar_x/screens/platform_screen.dart';
import 'package:similar_x/screens/post_detail_screen.dart';

import 'fake_adapter.dart';

/// A MaterialApp with the app's localizations, for pumping one screen.
/// Mirrors main.dart: the app uses the material_ui / cupertino_ui
/// forks, so their localization delegates are the ones that count —
/// the flutter_localizations Material delegate does not cover them.
Widget localized(Widget child) => MaterialApp(
      locale: const Locale('en'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: child,
    );

/// Pumps a page with an "Open" button that pushes the screen built by
/// [screenBuilder]; popped values are recorded in [result].
Future<void> pumpPushHarness(
  WidgetTester tester,
  Widget Function(BuildContext context) screenBuilder,
  List<bool?> result,
) async {
  await tester.pumpWidget(localized(
    Builder(
      builder: (BuildContext context) => Scaffold(
        body: Center(
          child: ElevatedButton(
            onPressed: () async {
              final bool? value = await Navigator.of(context).push<bool>(
                MaterialPageRoute<bool>(builder: screenBuilder),
              );
              result.add(value);
            },
            child: const Text('Open'),
          ),
        ),
      ),
    ),
  ));
  // The localizations delegates need a frame before the home builds.
  await tester.pumpAndSettle();
  await tester.tap(find.text('Open'));
  await tester.pumpAndSettle();
}

const Set<AdapterCapability> fullCaps = <AdapterCapability>{
  AdapterCapability.timeline,
  AdapterCapability.post,
  AdapterCapability.like,
  AdapterCapability.repost,
  AdapterCapability.comment,
};

void main() {
  group('unified timeline', () {
    testWidgets('merges adapters newest-first', (WidgetTester tester) async {
      final FakeAdapter fakeA = FakeAdapter(
        id: 'fake_a',
        displayName: 'Fake A',
        posts: <Post>[
          fakePost(
            id: 'a1',
            platformId: 'fake_a',
            text: 'A at ten',
            createdAt: DateTime(2026, 11, 17, 10, 0),
          ),
        ],
      );
      final FakeAdapter fakeB = FakeAdapter(
        id: 'fake_b',
        displayName: 'Fake B',
        posts: <Post>[
          fakePost(
            id: 'b1',
            platformId: 'fake_b',
            text: 'B at eleven',
            createdAt: DateTime(2026, 11, 17, 11, 0),
          ),
          fakePost(
            id: 'b2',
            platformId: 'fake_b',
            text: 'B at nine',
            createdAt: DateTime(2026, 11, 17, 9, 0),
          ),
        ],
      );
      await tester.pumpWidget(
        ChangeNotifierProvider<AppState>(
          create: (_) => AppState(adapters: <PlatformAdapter>[fakeA, fakeB]),
          child: const SimilarXApp(),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('A at ten'), findsOneWidget);
      expect(find.text('B at eleven'), findsOneWidget);
      expect(find.text('B at nine'), findsOneWidget);
      final double yEleven =
          tester.getTopLeft(find.text('B at eleven')).dy;
      final double yTen = tester.getTopLeft(find.text('A at ten')).dy;
      final double yNine = tester.getTopLeft(find.text('B at nine')).dy;
      expect(yEleven, lessThan(yTen));
      expect(yTen, lessThan(yNine));
    });

    testWidgets('filter chips narrow the feed', (WidgetTester tester) async {
      final FakeAdapter fakeA = FakeAdapter(
        id: 'fake_a',
        displayName: 'Fake A',
        posts: <Post>[
          fakePost(id: 'a1', platformId: 'fake_a', text: 'Only A'),
        ],
      );
      final FakeAdapter fakeB = FakeAdapter(
        id: 'fake_b',
        displayName: 'Fake B',
        posts: <Post>[
          fakePost(id: 'b1', platformId: 'fake_b', text: 'Only B'),
        ],
      );
      await tester.pumpWidget(
        ChangeNotifierProvider<AppState>(
          create: (_) => AppState(adapters: <PlatformAdapter>[fakeA, fakeB]),
          child: const SimilarXApp(),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(ChoiceChip, 'Fake B'));
      await tester.pumpAndSettle();
      expect(find.text('Only A'), findsNothing);
      expect(find.text('Only B'), findsOneWidget);

      await tester.tap(find.widgetWithText(ChoiceChip, 'All'));
      await tester.pumpAndSettle();
      expect(find.text('Only A'), findsOneWidget);
      expect(find.text('Only B'), findsOneWidget);
    });

    testWidgets('empty timeline shows the empty state',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        ChangeNotifierProvider<AppState>(
          create: (_) => AppState(
            adapters: <PlatformAdapter>[
              FakeAdapter(id: 'fake_a', displayName: 'Fake A'),
              FakeAdapter(id: 'fake_b', displayName: 'Fake B'),
            ],
          ),
          child: const SimilarXApp(),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('No posts yet — pull to refresh.'), findsOneWidget);
    });

    testWidgets('one failing adapter does not kill the feed',
        (WidgetTester tester) async {
      final FakeAdapter failing = FakeAdapter(
        id: 'fake_a',
        displayName: 'Fake A',
        timelineError: Exception('boom'),
      );
      final FakeAdapter working = FakeAdapter(
        id: 'fake_b',
        displayName: 'Fake B',
        posts: <Post>[
          fakePost(id: 'b1', platformId: 'fake_b', text: 'Still here'),
        ],
      );
      await tester.pumpWidget(
        ChangeNotifierProvider<AppState>(
          create: (_) =>
              AppState(adapters: <PlatformAdapter>[failing, working]),
          child: const SimilarXApp(),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Still here'), findsOneWidget);
      expect(
        find.textContaining('Some platforms failed to load'),
        findsOneWidget,
      );
    });

    testWidgets('like toggles optimistically', (WidgetTester tester) async {
      final FakeAdapter fake = FakeAdapter(
        id: 'fake_a',
        displayName: 'Fake A',
        capabilities: fullCaps,
        loggedIn: true,
        posts: <Post>[
          fakePost(
            id: 'a1',
            platformId: 'fake_a',
            text: 'Like me',
            likeCount: 2,
          ),
        ],
      );
      await tester.pumpWidget(
        ChangeNotifierProvider<AppState>(
          create: (_) => AppState(adapters: <PlatformAdapter>[fake]),
          child: const SimilarXApp(),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('2'), findsOneWidget);
      await tester.tap(find.byIcon(Icons.favorite_border));
      await tester.pumpAndSettle();
      expect(fake.likedIds, <String>['a1']);
      expect(find.text('3'), findsOneWidget);
    });
  });

  group('platform screen', () {
    testWidgets('shows timeline and login button when logged out',
        (WidgetTester tester) async {
      final FakeAdapter fake = FakeAdapter(
        id: 'fake_a',
        displayName: 'Fake A',
        capabilities: fullCaps,
        posts: <Post>[
          fakePost(id: 'a1', platformId: 'fake_a', text: 'Platform post'),
        ],
      );
      await tester.pumpWidget(
        localized(PlatformScreen(adapter: fake)),
      );
      await tester.pumpAndSettle();

      expect(find.text('Platform post'), findsOneWidget);
      expect(find.text('Log in'), findsOneWidget);
      // No compose button while logged out.
      expect(find.byIcon(Icons.edit), findsNothing);
    });

    testWidgets('login from the platform screen refreshes it',
        (WidgetTester tester) async {
      final FakeAdapter fake = FakeAdapter(
        id: 'fake_a',
        displayName: 'Fake A',
        capabilities: fullCaps,
        posts: <Post>[
          fakePost(id: 'a1', platformId: 'fake_a', text: 'Platform post'),
        ],
      );
      await tester.pumpWidget(
        localized(PlatformScreen(adapter: fake)),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Log in'));
      await tester.pumpAndSettle();
      expect(find.text('Log in to Fake A'), findsOneWidget);
      // The generic form: one button that calls adapter.login().
      await tester.tap(find.widgetWithText(FilledButton, 'Log in'));
      await tester.pumpAndSettle();
      expect(fake.loggedIn, isTrue);
      // Back on the platform screen, now with a compose button.
      expect(find.text('Platform post'), findsOneWidget);
      expect(find.byIcon(Icons.edit), findsOneWidget);
    });
  });

  group('login screen', () {
    testWidgets('generic form logs in and pops true',
        (WidgetTester tester) async {
      final FakeAdapter fake = FakeAdapter(
        id: 'fake_a',
        displayName: 'Fake A',
      );
      final List<bool?> result = <bool?>[];
      await pumpPushHarness(
        tester,
        (_) => LoginScreen(adapter: fake),
        result,
      );

      expect(find.text('Log in to Fake A'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Log in'));
      await tester.pumpAndSettle();
      expect(fake.loggedIn, isTrue);
      expect(result, <bool?>[true]);
    });

    testWidgets('bluesky form logs in with handle and app password',
        (WidgetTester tester) async {
      final MockClient mockClient = MockClient(
        (http.Request request) async {
          final String path = request.url.path;
          if (request.method == 'POST' &&
              path == '/xrpc/com.atproto.server.createSession') {
            final Map<String, dynamic> body =
                jsonDecode(request.body) as Map<String, dynamic>;
            if (body['identifier'] == 'alice.bsky.social' &&
                body['password'] == 'app-password-1234') {
              return http.Response(
                jsonEncode(<String, Object?>{
                  'did': 'did:plc:alice123',
                  'handle': 'alice.bsky.social',
                  'accessJwt': 'test-access-jwt',
                  'refreshJwt': 'test-refresh-jwt',
                  'active': true,
                }),
                200,
                headers: <String, String>{
                  'content-type': 'application/json',
                },
              );
            }
            return http.Response(
              jsonEncode(<String, Object?>{
                'error': 'InvalidPassword',
                'message': 'Invalid password',
              }),
              400,
            );
          }
          if (request.method == 'GET' &&
              path == '/xrpc/app.bsky.actor.getProfile') {
            return http.Response(
              jsonEncode(<String, Object?>{
                'did': 'did:plc:alice123',
                'handle': 'alice.bsky.social',
                'displayName': 'Alice',
                'followersCount': 10,
                'followsCount': 5,
                'postsCount': 42,
              }),
              200,
              headers: <String, String>{'content-type': 'application/json'},
            );
          }
          return http.Response('not found', 404);
        },
      );
      final FakeAccountStore store = FakeAccountStore();
      final BlueskyAdapter adapter = BlueskyAdapter(
        client: BlueskyClient(
          service: 'bsky.social',
          httpClient: mockClient,
        ),
        accountStore: store,
      );
      final List<bool?> result = <bool?>[];
      await pumpPushHarness(
        tester,
        (_) => LoginScreen(adapter: adapter),
        result,
      );

      await tester.enterText(
        find.widgetWithText(TextField, 'Handle'),
        'alice.bsky.social',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'App Password'),
        'app-password-1234',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Log in'));
      await tester.pumpAndSettle();
      expect(await adapter.isLoggedIn, isTrue);
      expect(result, <bool?>[true]);
    });
  });

  group('compose screen', () {
    testWidgets('posts to all selected platforms',
        (WidgetTester tester) async {
      final FakeAdapter fakeA = FakeAdapter(
        id: 'fake_a',
        displayName: 'Fake A',
        capabilities: fullCaps,
        loggedIn: true,
      );
      final FakeAdapter fakeB = FakeAdapter(
        id: 'fake_b',
        displayName: 'Fake B',
        capabilities: fullCaps,
        loggedIn: true,
      );
      final List<bool?> result = <bool?>[];
      await pumpPushHarness(
        tester,
        (_) => ComposeScreen(adapters: <PlatformAdapter>[fakeA, fakeB]),
        result,
      );

      await tester.enterText(
        find.widgetWithText(TextField, 'What’s happening?'),
        'Hello everywhere',
      );
      // The Post button enables only when the text is non-empty, so
      // pump a frame for the button state to update before tapping.
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Post'));
      await tester.pumpAndSettle();
      expect(fakeA.publishedTexts, <String>['Hello everywhere']);
      expect(fakeB.publishedTexts, <String>['Hello everywhere']);
      expect(result, <bool?>[true]);
    });

    testWidgets('reddit shows subreddit and title fields',
        (WidgetTester tester) async {
      final FakeAdapter reddit = FakeAdapter(
        id: 'reddit',
        displayName: 'Reddit',
        capabilities: fullCaps,
        loggedIn: true,
      );
      final List<bool?> result = <bool?>[];
      await pumpPushHarness(
        tester,
        (_) => ComposeScreen(adapters: <PlatformAdapter>[reddit]),
        result,
      );

      expect(find.widgetWithText(TextField, 'Subreddit'), findsOneWidget);
      expect(find.widgetWithText(TextField, 'Title'), findsOneWidget);
      await tester.enterText(
        find.widgetWithText(TextField, 'Subreddit'),
        'flutter',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'What’s happening?'),
        'Reddit post',
      );
      // The Post button enables only when the text is non-empty, so
      // pump a frame for the button state to update before tapping.
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Post'));
      await tester.pumpAndSettle();
      expect(reddit.publishedTexts, <String>['Reddit post']);
      expect(result, <bool?>[true]);
    });
  });

  group('post detail', () {
    testWidgets('shows comments and sends a reply',
        (WidgetTester tester) async {
      final Post post = fakePost(
        id: 'a1',
        platformId: 'fake_a',
        text: 'Original post',
        replyCount: 1,
      );
      final FakeAdapter fake = FakeAdapter(
        id: 'fake_a',
        displayName: 'Fake A',
        capabilities: fullCaps,
        loggedIn: true,
        comments: <Post>[
          fakePost(
            id: 'c1',
            platformId: 'fake_a',
            authorName: 'Bob',
            authorHandle: '@bob',
            text: 'First comment',
          ),
        ],
      );
      await tester.pumpWidget(
        localized(PostDetailScreen(post: post, adapter: fake)),
      );
      await tester.pumpAndSettle();

      expect(find.text('Original post'), findsOneWidget);
      expect(find.text('First comment'), findsOneWidget);
      await tester.enterText(
        find.widgetWithText(TextField, 'Write a reply…'),
        'My reply',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Reply'));
      await tester.pumpAndSettle();
      expect(fake.replies, <(String, String)>[('a1', 'My reply')]);
    });

    testWidgets('like calls the adapter', (WidgetTester tester) async {
      final Post post = fakePost(
        id: 'a1',
        platformId: 'fake_a',
        text: 'Likeable post',
        likeCount: 0,
      );
      final FakeAdapter fake = FakeAdapter(
        id: 'fake_a',
        displayName: 'Fake A',
        capabilities: fullCaps,
        loggedIn: true,
      );
      await tester.pumpWidget(
        localized(PostDetailScreen(post: post, adapter: fake)),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.favorite_border).first);
      await tester.pumpAndSettle();
      expect(fake.likedIds, <String>['a1']);
      expect(find.text('1'), findsWidgets);
    });
  });
}
