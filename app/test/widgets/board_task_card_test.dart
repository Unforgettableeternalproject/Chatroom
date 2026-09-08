import 'package:chatroom_app/core/theme/uep_theme.dart';
import 'package:chatroom_app/models/board.dart';
import 'package:chatroom_app/widgets/board_task_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Task 卡片：**色軸講誰，徽章講到哪**。
///
/// 這份測試釘的是那句話——認領與狀態是兩個正交的維度。最要緊的一條是
/// 「孤兒卡的狀態徽章不變」：把狀態一起打回待辦，一張做到一半而人不見了的
/// 卡就跟沒人碰過的長得一模一樣，而那正是最需要被看見的一種。
BoardTask _task({
  String status = 'todo',
  String claimState = '',
  String claimName = '',
  String claimKind = '',
  String orphanedReason = '',
  String? assignee,
}) => BoardTask(
  id: 't1',
  roomId: 'r1',
  checklistId: 'c1',
  title: '認領的條件式 UPDATE',
  boardSeq: 1,
  status: status,
  claimState: claimState,
  claimName: claimName,
  claimKind: claimKind,
  orphanedReason: orphanedReason,
  assigneeParticipantId: assignee,
);

Widget _wrap(Widget child) => MaterialApp(
  theme: buildUepTheme(Brightness.dark),
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

void main() {
  group('軸狀態', () {
    test('沒有人＝none', () {
      expect(_task().axis, ClaimAxis.none);
    });

    test('被指名但沒人站上去＝suggested', () {
      expect(_task(assignee: 'p9').axis, ClaimAxis.suggested);
    });

    test('持有中＝held', () {
      expect(_task(claimState: 'held', claimName: 'Nova').axis, ClaimAxis.held);
    });

    test('持有者不在了＝orphaned', () {
      expect(
        _task(claimState: 'orphaned', claimName: 'Kite').axis,
        ClaimAxis.orphaned,
      );
    });

    test('🔴 已收尾又是孤兒＝Hub 的資料矛盾，debug build 要炸出來', () {
      // 這個組合是 Hub 的孤兒化沒排除 done/cancelled 造成的（F6）。
      // axis 的判斷順序會讓它在畫面上看不出來——**下游處理得越漂亮，
      // 上游的錯誤越安靜**。assert 只在 debug 執行，release 整段移除，
      // 所以開發時抓得到、使用者不會看到任何東西。
      expect(
        () => _task(status: 'done', claimState: 'orphaned').axis,
        throwsA(isA<AssertionError>()),
      );
    });

    test('完成與取消＝completed（收合成單行）', () {
      expect(_task(status: 'done').axis, ClaimAxis.completed);
      expect(_task(status: 'cancelled').axis, ClaimAxis.completed);
    });

    test('孤兒的軸狀態不受它做到哪影響——那是另一個維度', () {
      for (final s in ['todo', 'in_progress', 'blocked']) {
        expect(
          _task(status: s, claimState: 'orphaned').axis,
          ClaimAxis.orphaned,
        );
      }
    });
  });

  testWidgets('🔴 孤兒卡的狀態徽章不變——變的是人不是進度', (tester) async {
    await tester.pumpWidget(
      _wrap(
        BoardTaskCard(
          task: _task(
            status: 'in_progress',
            claimState: 'orphaned',
            claimName: 'Kite',
            claimKind: 'claude',
            orphanedReason: 'idle',
          ),
        ),
      ),
    );

    // 徽章照舊說「進行中」，不是被打回「待辦」
    expect(find.text('進行中'), findsOneWidget);
    expect(find.text('待辦'), findsNothing);
  });

  testWidgets('孤兒卡：名字劃掉、講出為什麼不在了', (tester) async {
    await tester.pumpWidget(
      _wrap(
        BoardTaskCard(
          task: _task(
            status: 'in_progress',
            claimState: 'orphaned',
            claimName: 'Kite',
            claimKind: 'claude',
            orphanedReason: 'idle',
          ),
        ),
      ),
    );

    final name = tester.widget<Text>(find.text('Kite'));
    expect(name.style?.decoration, TextDecoration.lineThrough);
    expect(find.textContaining('因閒置移出'), findsOneWidget);
  });

  testWidgets('Hub 沒給 orphaned_reason 時只說「已不在房內」，不要猜', (tester) async {
    await tester.pumpWidget(
      _wrap(
        BoardTaskCard(
          task: _task(
            status: 'in_progress',
            claimState: 'orphaned',
            claimName: 'Kite',
          ),
        ),
      ),
    );

    expect(find.textContaining('已不在房內'), findsOneWidget);
    expect(find.textContaining('閒置'), findsNothing);
  });

  testWidgets('Hub 沒給 claim_kind 時不畫種類徽章，不要猜', (tester) async {
    await tester.pumpWidget(
      _wrap(
        BoardTaskCard(
          task: _task(claimState: 'held', claimName: 'Nova'),
        ),
      ),
    );

    expect(find.text('CLAUDE'), findsNothing);
    expect(find.text('Nova'), findsOneWidget);
  });

  testWidgets('🔴 認領失敗畫成事實，不是錯誤——沒有重試按鈕', (tester) async {
    await tester.pumpWidget(
      _wrap(
        BoardTaskCard(
          task: _task(claimState: 'held', claimName: 'Swift-Falcon'),
          conflict: 'Swift-Falcon',
          onClaim: () {},
        ),
      ),
    );

    expect(find.textContaining('已經被 Swift-Falcon 領走了'), findsOneWidget);
    expect(find.text('重試'), findsNothing);
    expect(find.text('認領'), findsNothing);
  });

  testWidgets('可撿回的卡：金框與「撿回」只給本人', (tester) async {
    await tester.pumpWidget(
      _wrap(
        Column(
          children: [
            BoardTaskCard(
              task: _task(claimState: 'orphaned', claimName: 'Nova'),
              isMineToReclaim: true,
              onClaim: () {},
            ),
          ],
        ),
      ),
    );

    expect(find.textContaining('你上一世領走的卡'), findsOneWidget);
    expect(find.text('撿回'), findsOneWidget);
  });

  testWidgets('別人的孤兒卡是「接手」，不是「撿回」', (tester) async {
    await tester.pumpWidget(
      _wrap(
        BoardTaskCard(
          task: _task(claimState: 'orphaned', claimName: 'Kite'),
          onClaim: () {},
        ),
      ),
    );

    expect(find.text('接手'), findsOneWidget);
    expect(find.text('撿回'), findsNothing);
  });

  testWidgets('完成的卡收合成單行——誰做的退成註記', (tester) async {
    await tester.pumpWidget(
      _wrap(
        BoardTaskCard(
          task: _task(status: 'done', claimState: 'held', claimName: 'Nova'),
          onClaim: () {},
        ),
      ),
    );

    expect(find.text('✓'), findsOneWidget);
    // 收合的卡不帶動作
    expect(find.text('釋放認領'), findsNothing);
    // **狀態徽章照留**（設計稿 artboard 02）：徽章欄位不留空，一整欄看
    // 下來狀態都在同一個 x 上，✓ 是輔助不是替代。
    //
    // 這條原本斷言「不帶狀態徽章」——那是我的視覺偏好混進了語意測試，
    // 不在四條紅線裡，設計稿也畫了徽章。2026-09-01 由 UI 端指出後改口。
    expect(find.text('完成'), findsOneWidget);
  });

  testWidgets('取消的卡同樣留著徽章', (tester) async {
    await tester.pumpWidget(
      _wrap(BoardTaskCard(task: _task(status: 'cancelled'))),
    );

    expect(find.text('✕'), findsOneWidget);
    expect(find.text('已取消'), findsOneWidget);
  });

  testWidgets('被指名的卡：講出建議給誰，但誰都能領', (tester) async {
    await tester.pumpWidget(
      _wrap(
        BoardTaskCard(
          task: _task(assignee: 'p9'),
          assigneeName: 'Swift-Falcon',
          onClaim: () {},
        ),
      ),
    );

    expect(find.textContaining('建議給'), findsOneWidget);
    expect(find.text('Swift-Falcon'), findsOneWidget);
    // 指定是建議不是鎖：認領的入口照樣在
    expect(find.text('我來做'), findsOneWidget);
  });

  testWidgets('被指名的人已經離開時，講出來而不是留白', (tester) async {
    await tester.pumpWidget(
      _wrap(
        BoardTaskCard(
          task: _task(assignee: 'p9'),
          onClaim: () {},
        ),
      ),
    );

    expect(find.textContaining('已不在房內'), findsOneWidget);
  });

  testWidgets('🔴 搬走的卡：徽章要說「已搬走」，不是吐英文狀態碼', (tester) async {
    // 抽屜那顆徽章早就有 `moved`（`board_task_drawer.dart`），卡片這顆漏了。
    // 漏掉的症狀不報錯：卡片照樣畫得出來，只是徽章上寫著 `moved`——
    // 讀板的人在一排中文徽章裡看到一個英文字，第一個念頭是「這張壞了」，
    // 而不是「這件事搬到別處做了」。**找不到那張卡的體感就是這麼來的。**
    await tester.pumpWidget(
      _wrap(BoardTaskCard(task: _task(status: 'moved'))),
    );

    expect(find.text('已搬走'), findsOneWidget);
    expect(find.text('moved'), findsNothing);
  });

  testWidgets('🔴 搬走的卡不可以長成「已完成」', (tester) async {
    // 艾斯維爾的實測截圖（09/08）：一張 moved 卡在板上帶著綠色 ✓ 與完成的
    // 填底，與旁邊真的做完的卡一模一樣。他的原話是「會讓人誤以為是已完成」
    // ——「找不到」的真正意思是**它混進完成堆裡認不出來**，不是它不見了。
    //
    // 收尾樣式當初只分了兩態（`cancelled ? ✕ : ✓`），moved 落進 else，
    // 於是拿到 done 的符號與顏色。三個結局要有三個樣子。
    await tester.pumpWidget(
      _wrap(BoardTaskCard(task: _task(status: 'moved'))),
    );

    expect(find.text('✓'), findsNothing, reason: '打勾是「這裡做完了」，而它沒有');
    expect(find.text('→'), findsOneWidget, reason: '搬走要有自己的符號');
  });
}
