import 'dart:io';

import 'package:chatroom_app/core/theme/uep_theme.dart';
import 'package:chatroom_app/screens/host/runner_service_row.dart';
import 'package:chatroom_app/state/kit_installer.dart';
import 'package:chatroom_app/state/runner_service.dart';
import 'package:chatroom_app/widgets/uep_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';

import '../helpers/l10n.dart';

/// 執行器的起停開關。
///
/// 🔴 **停止的順序是這一列存在的理由**：排程工作設了失敗自動重啟加上每 5
/// 分鐘的存活觸發，所以 `Stop` ＋殺進程會在一分鐘內被拉回來。必須先
/// `Disable-ScheduledTask`。這裡驗的就是那個順序，不是驗「有沒有跑過那幾個
/// 指令」。
void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);

  Widget wrap(_FakeRunner runner, {int activeRuns = 0}) => ProviderScope(
        overrides: [
          kitInstallSupportedProvider.overrideWithValue(true),
          kitProcessRunnerProvider.overrideWithValue(runner),
          runnerTaskNameProvider.overrideWith((ref) async => 'ChatroomRunner'),
          runnerActiveRunCountProvider.overrideWith((ref) async => activeRuns),
        ],
        child: MaterialApp(
          locale: kTestLocale,
          localizationsDelegates: kTestLocalizationsDelegates,
          supportedLocales: kTestSupportedLocales,
          theme: buildUepTheme(Brightness.dark),
          home: const Scaffold(
              body: SingleChildScrollView(child: RunnerServiceRow())),
        ),
      );

  UepButton button(WidgetTester tester) =>
      tester.widget<UepButton>(find.byType(UepButton));

  group('狀態怎麼顯示', () {
    testWidgets('工作在跑 → 執行中，按鈕是停止', (tester) async {
      await tester.pumpWidget(wrap(_FakeRunner(task: 'Running', procs: 1)));
      await tester.pumpAndSettle();

      expect(find.text('執行中'), findsOneWidget);
      expect(button(tester).label, '停止執行器');
    });

    testWidgets('Ready 且沒有進程 → 已停止，按鈕是啟動', (tester) async {
      await tester.pumpWidget(wrap(_FakeRunner(task: 'Ready', procs: 0)));
      await tester.pumpAndSettle();

      expect(find.text('已停止'), findsOneWidget);
      expect(button(tester).label, '啟動執行器');
    });

    testWidgets('🔴 Disabled 要講成已停用，不是已停止', (tester) async {
      await tester.pumpWidget(wrap(_FakeRunner(task: 'Disabled', procs: 0)));
      await tester.pumpAndSettle();

      expect(find.text('已停用'), findsOneWidget,
          reason: '停用的觸發器不按啟動就不會自己回來，與「這一刻沒在跑」是兩件事');
      expect(button(tester).label, '啟動執行器');
    });

    testWidgets('Ready 但有人手跑一份 → 算執行中', (tester) async {
      await tester.pumpWidget(wrap(_FakeRunner(task: 'Ready', procs: 2)));
      await tester.pumpAndSettle();

      expect(find.text('執行中'), findsOneWidget);
    });

    testWidgets('🔴 查不到狀態不卡在讀取中，把那一句轉述出來', (tester) async {
      await tester.pumpWidget(wrap(_FakeRunner(task: 'Ready', statusFails: true)));
      await tester.pumpAndSettle();

      expect(find.text('狀態不明'), findsOneWidget);
      expect(find.textContaining('沒有權限'), findsOneWidget);
    });
  });

  group('停止', () {
    testWidgets('🔴 先停用、再停止、最後才殺進程', (tester) async {
      final runner = _FakeRunner(task: 'Running', procs: 1);
      await tester.pumpWidget(wrap(runner));
      await tester.pumpAndSettle();

      await tester.tap(find.byType(UepButton));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, '停止執行器'));
      await tester.pumpAndSettle();

      final steps = runner.commands
          .where((c) => !c.contains('Get-ScheduledTask'))
          .toList();
      expect(steps.length, 3);
      expect(steps[0], contains('Disable-ScheduledTask'));
      expect(steps[1], contains('Stop-ScheduledTask'));
      expect(steps[2], contains('Stop-Process'));
      expect(steps[2], contains('-m chatroom_runner'));
      expect(steps.first, contains("'ChatroomRunner'"));
    });

    testWidgets('🔴 手上還有 run 時，確認框要講出有幾筆與後果', (tester) async {
      final runner = _FakeRunner(task: 'Running', procs: 1);
      await tester.pumpWidget(wrap(runner, activeRuns: 3));
      await tester.pumpAndSettle();

      await tester.tap(find.byType(UepButton));
      await tester.pumpAndSettle();

      expect(
          find.text('目前有 3 筆派工在跑，停止會把它們砍掉並在 Hub 上標成失敗。'),
          findsOneWidget);
    });

    testWidgets('沒有 run 時是一般確認，不講被砍掉的那句', (tester) async {
      final runner = _FakeRunner(task: 'Running', procs: 1);
      await tester.pumpWidget(wrap(runner));
      await tester.pumpAndSettle();

      await tester.tap(find.byType(UepButton));
      await tester.pumpAndSettle();

      expect(find.textContaining('筆派工在跑'), findsNothing);
      expect(find.textContaining('不再接派工'), findsOneWidget);
    });

    testWidgets('取消 → 一個指令都不跑', (tester) async {
      final runner = _FakeRunner(task: 'Running', procs: 1);
      await tester.pumpWidget(wrap(runner));
      await tester.pumpAndSettle();
      runner.commands.clear();

      await tester.tap(find.byType(UepButton));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, '取消'));
      await tester.pumpAndSettle();

      expect(runner.commands.where((c) => c.contains('Disable-ScheduledTask')),
          isEmpty);
    });

    testWidgets('🔴 失敗時把 stderr 那一句講出來', (tester) async {
      final runner =
          _FakeRunner(task: 'Running', procs: 1, actionFails: true);
      await tester.pumpWidget(wrap(runner));
      await tester.pumpAndSettle();

      await tester.tap(find.byType(UepButton));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, '停止執行器'));
      await tester.pumpAndSettle();

      expect(find.textContaining('存取被拒'), findsOneWidget);
      expect(runner.commands.where((c) => c.contains('Stop-ScheduledTask')),
          isEmpty,
          reason: '第一步就失敗了，後面不該照跑');
    });
  });

  group('啟動', () {
    testWidgets('🔴 先啟用再啟動——停過一次之後觸發器是停用的', (tester) async {
      final runner = _FakeRunner(task: 'Disabled', procs: 0);
      await tester.pumpWidget(wrap(runner));
      await tester.pumpAndSettle();
      runner.commands.clear();

      await tester.tap(find.byType(UepButton));
      await tester.pumpAndSettle();

      final steps = runner.commands
          .where((c) => !c.contains('Get-ScheduledTask'))
          .toList();
      expect(steps.length, 2);
      expect(steps[0], contains('Enable-ScheduledTask'));
      expect(steps[1], contains('Start-ScheduledTask'));
    });

    testWidgets('啟動不問確認框', (tester) async {
      final runner = _FakeRunner(task: 'Ready', procs: 0);
      await tester.pumpWidget(wrap(runner));
      await tester.pumpAndSettle();

      await tester.tap(find.byType(UepButton));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing);
    });
  });
}

/// 假的子進程：記下每一道 PowerShell 指令，並照劇本回答狀態查詢。
///
/// **絕不真的動這台機器上的排程工作**——測試跑的時候正式站的執行器手上
/// 可能有工作在跑。
class _FakeRunner implements KitProcessRunner {
  _FakeRunner({
    this.task = 'Ready',
    this.procs = 0,
    this.statusFails = false,
    this.actionFails = false,
  });

  final String task;
  final int procs;
  final bool statusFails;
  final bool actionFails;

  final List<String> commands = [];

  @override
  Future<ProcessResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
  }) async {
    final script = arguments.last;
    commands.add(script);
    if (script.contains('Get-ScheduledTask')) {
      if (statusFails) return ProcessResult(0, 1, '', '沒有權限查排程工作');
      return ProcessResult(0, 0, 'TASK=$task\nPROC=$procs\n', '');
    }
    if (actionFails) return ProcessResult(0, 1, '', '存取被拒\n第二行不要');
    return ProcessResult(0, 0, '', '');
  }
}
