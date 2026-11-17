// Widget tests: the three tabs render with a fake backend, and the tab
// bar switches pages. Uses a temp documents dir + mocked preferences.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tiny_trainer/l10n/strings.dart';
import 'package:tiny_trainer/main.dart';
import 'package:tiny_trainer/services/training_manager.dart';
import 'package:tiny_trainer/ui/brain_page.dart';
import 'package:tiny_trainer/ui/chat_page.dart';
import 'package:tiny_trainer/ui/train_page.dart';

import 'fake_engine_backend.dart';

void main() {
  late Directory tmpDir;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tmpDir = await Directory.systemTemp.createTemp('tiny_trainer_widget_test');
  });

  tearDown(() async {
    if (await tmpDir.exists()) await tmpDir.delete(recursive: true);
  });

  testWidgets('three tabs render and switch', (tester) async {
    final manager = TrainingManager(
      backend: FakeEngineBackend(),
      documentsDir: tmpDir,
    );
    addTearDown(manager.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: _TestShell(manager: manager),
      ),
    );
    await tester.pumpAndSettle();

    // Train tab is shown first: corpus section + start button.
    expect(find.text('语料'), findsOneWidget);
    expect(find.text('开始训练'), findsOneWidget);
    expect(find.text('超参数'), findsOneWidget);

    // Switch to Chat.
    await tester.tap(find.text('对话'));
    await tester.pumpAndSettle();
    expect(find.text('生成'), findsOneWidget);

    // Switch to Brain.
    await tester.tap(find.text('大脑'));
    await tester.pumpAndSettle();
    expect(find.text('大脑信息'), findsOneWidget);
    expect(find.text('导出大脑 (.brain)'), findsOneWidget);
    expect(find.text('新建大脑'), findsOneWidget);
  });

  testWidgets('app boots with the real main entry', (tester) async {
    await tester.pumpWidget(
      const TinyTrainerApp(initialLocale: AppLocale.zh),
    );
    await tester.pumpAndSettle();
    expect(find.text('TinyTrainer'), findsWidgets);
    expect(find.text('训练'), findsWidgets);
  });
}

/// Minimal shell hosting the three pages (mirrors main.dart's scaffold).
class _TestShell extends StatefulWidget {
  final TrainingManager manager;
  const _TestShell({required this.manager});

  @override
  State<_TestShell> createState() => _TestShellState();
}

class _TestShellState extends State<_TestShell> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    return StringsScope(
      strings: const Strings(AppLocale.zh),
      onLocaleChanged: (_) {},
      child: Scaffold(
        body: IndexedStack(
          index: _index,
          children: [
            TrainPage(manager: widget.manager),
            ChatPage(manager: widget.manager),
            BrainPage(manager: widget.manager),
          ],
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _index,
          onDestinationSelected: (i) => setState(() => _index = i),
          destinations: const [
            NavigationDestination(icon: Icon(Icons.school), label: '训练'),
            NavigationDestination(
              icon: Icon(Icons.chat_bubble_outline),
              label: '对话',
            ),
            NavigationDestination(icon: Icon(Icons.psychology), label: '大脑'),
          ],
        ),
      ),
    );
  }
}
