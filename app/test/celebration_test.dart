import 'package:chatroom_app/celebration/celebration_controller.dart';
import 'package:chatroom_app/celebration/celebration_highlight.dart';
import 'package:chatroom_app/celebration/celebration_logic.dart';
import 'package:chatroom_app/celebration/confetti_overlay.dart';
import 'package:chatroom_app/core/config/app_settings.dart';
import 'package:chatroom_app/models/message.dart';
import 'package:chatroom_app/notifications/notification_center.dart';
import 'package:chatroom_app/state/app_providers.dart';
import 'package:chatroom_app/ws/room_feed.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _now = DateTime.utc(2026, 11, 11, 12, 0, 0);

Message sys(
  int seq,
  String event, {
  String? senderId,
  DateTime? at,
  bool deleted = false,
}) => Message(
  id: 'm$seq',
  seq: seq,
  updateSeq: 0,
  kind: 'system',
  content: '',
  createdAt: (at ?? _now).toIso8601String(),
  senderId: senderId,
  systemEvent: event,
  deleted: deleted,
);

class FakeSound implements CelebrationSound {
  int plays = 0;
  @override
  Future<void> play() async => plays++;
}

void main() {
  group('偏好', () {
    test('預設關，key 是 chatroom.celebration_mode，落盤並同步快照', () async {
      SharedPreferences.setMockInitialValues({});
      final settings = SettingsRepository(
        await SharedPreferences.getInstance(),
      );
      expect(settings.celebrationMode, isFalse);

      final container = ProviderContainer(
        overrides: [
          settingsRepoProvider.overrideWithValue(settings),
          initialConfigProvider.overrideWithValue(
            AppConfig.fromSettings(settings, token: '', deviceKey: 'd'),
          ),
        ],
      );
      addTearDown(container.dispose);
      expect(container.read(appConfigProvider).celebrationMode, isFalse);

      await container.read(appConfigProvider.notifier).setCelebrationMode(true);
      expect(container.read(appConfigProvider).celebrationMode, isTrue);
      expect(settings.prefs.getBool('chatroom.celebration_mode'), isTrue);
      expect(
        AppConfig.fromSettings(
          settings,
          token: '',
          deviceKey: 'd',
        ).celebrationMode,
        isTrue,
      );
    });
  });

  group('shouldCelebrate', () {
    bool run(
      Message m, {
      bool enabled = true,
      bool ops = false,
      DateTime? now,
    }) =>
        shouldCelebrate(m, enabled: enabled, roomIsOps: ops, now: now ?? _now);

    test('成員加入、任務完成會觸發（任何房）', () {
      expect(run(sys(1, 'join')), isTrue);
      expect(run(sys(2, 'board_task_done')), isTrue);
    });

    test('派工成功只在派工房觸發', () {
      expect(run(sys(1, 'run_done'), ops: true), isTrue);
      expect(run(sys(1, 'run_done'), ops: false), isFalse);
    });

    test('失敗、取消、其他 system 事件不觸發', () {
      for (final e in [
        'run_failed',
        'run_cancelled',
        'run_running',
        'leave',
        'pin',
      ]) {
        expect(run(sys(1, e), ops: true), isFalse, reason: e);
      }
    });

    test('模式關閉不觸發', () {
      expect(run(sys(1, 'join'), enabled: false), isFalse);
    });

    test('太舊的訊息（補訊／重連重放）、時間無法解析、已刪除都不觸發', () {
      final old = _now.subtract(const Duration(minutes: 5));
      expect(run(sys(1, 'join', at: old)), isFalse);
      expect(
        run(sys(1, 'join', at: _now.subtract(const Duration(seconds: 10)))),
        isTrue,
      );
      expect(
        run(
          const Message(
            id: 'x',
            seq: 1,
            updateSeq: 0,
            kind: 'system',
            content: '',
            createdAt: '',
            systemEvent: 'join',
          ),
        ),
        isFalse,
      );
      expect(run(sys(1, 'join', deleted: true)), isFalse);
    });
  });

  group('節流與控制器', () {
    test('間隔內的事件被合併，過了間隔可再放', () {
      var t = _now;
      final th = CelebrationThrottle(clock: () => t);
      expect(th.tryAcquire(), isTrue);
      t = t.add(const Duration(milliseconds: 1000));
      expect(th.tryAcquire(), isFalse);
      t = t.add(kCelebrationMinGap);
      expect(th.tryAcquire(), isTrue);
    });

    test('一次放一組彩花與一次音效；節流內不重複', () async {
      final t = _now;
      final sound = FakeSound();
      final c = CelebrationController(
        sound: sound,
        throttle: CelebrationThrottle(clock: () => t),
      );
      addTearDown(c.dispose);
      var bursts = 0;
      c.bursts.listen((_) => bursts++);

      expect(c.celebrate(), isTrue);
      expect(c.celebrate(), isFalse);
      expect(c.celebrate(), isFalse);
      await Future<void>.delayed(Duration.zero);
      expect(bursts, 1);
      expect(sound.plays, 1);
    });
  });

  group('NotificationCenter.liveSystemEvents', () {
    late Map<String, RoomFeed> feeds;
    late NotificationCenter center;
    late List<LiveSystemEvent> events;

    RoomFeed subscribe(String roomId, {String? participantId}) =>
        feeds.putIfAbsent(roomId, () => RoomFeed(roomId));

    setUp(() {
      feeds = {};
      events = [];
      center = NotificationCenter(subscribe, (_) {}, (_, _) {});
      center.liveSystemEvents.listen(events.add);
    });
    tearDown(() => center.dispose());

    Future<void> pump() => Future<void>.delayed(Duration.zero);

    test('首批歷史快照不送；之後的三種事件才送，失敗的 run 不送', () async {
      center.follow('r1', roomName: 'R', myParticipantId: 'me');
      feeds['r1']!.upsertAll([sys(1, 'join'), sys(2, 'run_done')]);
      await pump();
      expect(events, isEmpty);

      feeds['r1']!.upsertAll([
        sys(3, 'join', senderId: 'p-other'),
        sys(4, 'board_task_done'),
        sys(5, 'run_done'),
        sys(6, 'run_failed'),
        sys(7, 'run_cancelled'),
      ]);
      await pump();
      expect(events.map((e) => e.message.systemEvent), [
        'join',
        'board_task_done',
        'run_done',
      ]);
    });

    test('自己的加入不送（增量路徑與補投路徑）', () async {
      center.follow('r1', roomName: 'R', myParticipantId: 'me');
      feeds['r1']!.upsertAll([sys(1, 'join', senderId: 'old')]);
      await pump();

      feeds['r1']!.upsertAll([sys(2, 'join', senderId: 'me')]);
      await pump();
      expect(events, isEmpty);

      // 訂閱先於 join：加入訊息被當成歷史，再由 expectJoin 補投
      center.follow('r2', roomName: 'R2');
      feeds['r2']!.upsertAll([sys(1, 'join', senderId: 'me')]);
      await pump();
      center.expectJoin('r2', 'm1');
      await pump();
      expect(events, isEmpty);
    });
  });

  group('彩花層', () {
    testWidgets('burst 後會畫、結束後清掉，且不吃觸控', (tester) async {
      var taps = 0;
      final sound = FakeSound();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [celebrationSoundProvider.overrideWithValue(sound)],
          child: MaterialApp(
            home: CelebrationOverlay(
              child: Center(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => taps++,
                  child: const SizedBox(width: 100, height: 100, key: Key('t')),
                ),
              ),
            ),
          ),
        ),
      );
      final container = ProviderScope.containerOf(
        tester.element(find.byType(CelebrationOverlay)),
      );
      container.read(celebrationControllerProvider).celebrate();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      final painters = find.descendant(
        of: find.byType(CelebrationOverlay),
        matching: find.byWidgetPredicate(
          (w) => w is CustomPaint && w.painter is ConfettiPainter,
        ),
      );
      expect(painters, findsOneWidget);

      await tester.tap(find.byKey(const Key('t')));
      expect(taps, 1);

      await tester.pump(kConfettiDuration);
      await tester.pump();
      expect(painters, findsNothing);
      expect(sound.plays, 1);
    });
  });

  group('觸發訊息的標示', () {
    Widget host(String id) => MaterialApp(
      home: CelebrationHighlight(
        key: ValueKey('h-$id'),
        messageId: id,
        child: Column(
          children: const [
            CelebrationGlowText(
              '文字',
              key: Key('txt'),
              style: TextStyle(color: Colors.grey),
            ),
            SizedBox(key: Key('row'), width: 50, height: 20),
          ],
        ),
      ),
    );

    // A 案：只有文字本身發光（Text 帶 shadows），沒有任何包住整列的裝飾
    Finder glow() => find.descendant(
      of: find.byType(CelebrationHighlight),
      matching: find.byWidgetPredicate(
        (w) => w is Text && (w.style?.shadows?.isNotEmpty ?? false),
      ),
    );

    testWidgets('只有被標記的 id 會播；沒標的不播', (tester) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(celebrationHighlightsProvider.notifier).mark('a');

      Future<void> mount(String id) => tester.pumpWidget(
        UncontrolledProviderScope(container: container, child: host(id)),
      );

      await mount('b');
      await tester.pump(const Duration(milliseconds: 500));
      expect(glow(), findsNothing);

      await mount('a');
      await tester.pump(const Duration(milliseconds: 500));
      expect(glow(), findsOneWidget);
      // 整列不被背景／光暈包住，只有文字變金色
      expect(
        find.descendant(
          of: find.byType(CelebrationHighlight),
          matching: find.byType(DecoratedBox),
        ),
        findsNothing,
      );
      final text = tester.widget<Text>(
        find.descendant(
          of: find.byKey(const Key('txt')),
          matching: find.byType(Text),
        ),
      );
      expect(text.style!.color, isNot(Colors.grey));
      await tester.pump(kConfettiDuration);
      await tester.pump();
      expect(glow(), findsNothing);
    });

    testWidgets('重建（捲走再捲回來）不重播', (tester) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(celebrationHighlightsProvider.notifier).mark('a');
      Future<void> mount(Widget w) => tester.pumpWidget(
        UncontrolledProviderScope(container: container, child: w),
      );

      await mount(host('a'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(glow(), findsOneWidget);
      await tester.pump(kConfettiDuration);

      await mount(const MaterialApp(home: SizedBox()));
      await mount(host('a'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(glow(), findsNothing);
    });

    testWidgets('tile 早就在畫面上，之後才標記也會播', (tester) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(container: container, child: host('a')),
      );
      container.read(celebrationHighlightsProvider.notifier).mark('a');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(glow(), findsOneWidget);
      await tester.pump(kConfettiDuration);
    });

    test('超過窗口才建出來的 tile 不播；模式關閉時沒人 mark', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final n = container.read(celebrationHighlightsProvider.notifier);
      var t = _now;
      n.clock = () => t;
      n.mark('a');
      t = t.add(kCelebrationHighlightWindow + const Duration(seconds: 1));
      expect(n.consume('a'), isFalse);
      // 從未 mark（模式關閉或被節流丟掉）
      expect(n.consume('never'), isFalse);
    });
  });
}
