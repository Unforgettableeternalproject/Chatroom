import 'package:chatroom_app/models/board.dart';
import 'package:flutter_test/flutter_test.dart';

/// 聊天室 app bar 上 Board 入口的四種狀態（設計稿 artboard 06）。
///
/// 規則：**只有「等你確認」點亮**——那是唯一需要人動手、而且只有人能動的事。
/// 有進度、有孤兒都只是資訊。每個按鈕都在喊的話，就沒有一個在喊了。
///
/// 測的是 [BoardSnapshot.entryHint] 本人，不是它在 widget 裡的副本——
/// 複製一份判斷來測，測到的只會是那份副本自己。
/// ⚠️ 沒有明確給 checklist 時**自動補上父層**。
///
/// 計數的母體是「畫面上看得到的 Task」，而看得到與否要沿著
/// checklist → objective 走上去判定。父層不存在的 Task 是這份 fixture 的
/// 產物，真實資料裡不會有——留著它會讓每一條測試都在測一個不存在的情況。
BoardSnapshot _snap({
  List<BoardTask> tasks = const [],
  List<BoardObjective> objectives = const [],
  List<BoardChecklist> checklists = const [],
}) {
  final lists = [...checklists];
  final objs = [...objectives];
  if (tasks.isNotEmpty && lists.isEmpty) {
    lists.add(_c('c', 'auto-o'));
    objs.add(_o('auto-o'));
  }
  return BoardSnapshot(
    tasks: {for (final t in tasks) t.id: t},
    objectives: {for (final o in objs) o.id: o},
    checklists: {for (final c in lists) c.id: c},
  );
}

BoardTask _t(String id,
        {String status = 'todo',
        String claimState = '',
        bool deleted = false,
        String checklistId = 'c'}) =>
    BoardTask(
      id: id,
      roomId: 'r',
      checklistId: checklistId,
      title: id,
      boardSeq: 1,
      status: status,
      claimState: claimState,
      deleted: deleted,
    );

BoardChecklist _c(String id, String objectiveId, {String status = 'open'}) =>
    BoardChecklist(
      id: id,
      roomId: 'r',
      objectiveId: objectiveId,
      title: id,
      boardSeq: 1,
      status: status,
    );

BoardObjective _o(String id, {String status = 'active'}) => BoardObjective(
      id: id,
      roomId: 'r',
      title: id,
      boardSeq: 1,
      status: status,
    );

void main() {
  test('空板：什麼都不加，不點亮', () {
    final h = _snap().entryHint;
    expect(h.label, isEmpty);
    expect(h.needsYou, isFalse);
  });

  test('有進度：顯示數字，**不點亮**——數字是資訊不是警示', () {
    final h = _snap(tasks: [_t('a', status: 'done'), _t('b')]).entryHint;
    expect(h.label, '1/2');
    expect(h.needsYou, isFalse);
  });

  test('有孤兒：直接把數字說出來，仍不點亮', () {
    final h = _snap(tasks: [
      _t('a', status: 'in_progress', claimState: 'orphaned'),
      _t('b'),
    ]).entryHint;
    expect(h.label, '1 孤兒');
    expect(h.needsYou, isFalse);
  });

  test('🔴 只有「等你確認」點亮', () {
    final h = _snap(
      tasks: [_t('a')],
      objectives: [_o('o1', status: 'review')],
    ).entryHint;
    expect(h.label, '1 等你確認');
    expect(h.needsYou, isTrue);
  });

  test('等你確認蓋過孤兒——需要你動手的排在只是資訊的前面', () {
    final h = _snap(
      tasks: [_t('a', claimState: 'orphaned')],
      objectives: [_o('o1', status: 'review')],
    ).entryHint;
    expect(h.needsYou, isTrue);
    expect(h.label, contains('等你確認'));
  });

  test('🔴 verified 也在等人類——漏掉它，週期會停在倒數第二格', () {
    // Objective 是四段：active → review → verified → done。
    // verify 與 complete 是兩個獨立的動作，**都只有人類推得動**。
    // 漏算 verified 的後果比漏算 review 更糟：入口不亮、沒有通知，
    // 而畫面上寫著「已確認」——看起來像收工了。
    final h = _snap(
      tasks: [_t('a')],
      objectives: [_o('o1', status: 'verified')],
    ).entryHint;
    expect(h.needsYou, isTrue);
    expect(h.label, '1 等你收尾');
  });

  test('review 與 verified 同時存在時合計，文案不假裝只有一種', () {
    final h = _snap(
      tasks: [_t('a')],
      objectives: [
        _o('o1', status: 'review'),
        _o('o2', status: 'verified'),
      ],
    ).entryHint;
    expect(h.needsYou, isTrue);
    expect(h.label, '2 等你');
  });

  test('done 不再需要任何人', () {
    final h = _snap(
      tasks: [_t('a')],
      objectives: [_o('o1', status: 'done')],
    ).entryHint;
    expect(h.needsYou, isFalse);
    expect(h.label, '0/1');
  });

  test('軟刪除的卡不進計數', () {
    final h = _snap(tasks: [_t('a'), _t('b', deleted: true)]).entryHint;
    expect(h.label, '0/1');
  });

  test('整塊板只剩軟刪除的卡＝空板', () {
    expect(_snap(tasks: [_t('a', deleted: true)]).entryHint.label, isEmpty);
  });

  /// 顯示側一路濾掉被取消的父層，計數側原本拿整張 tasks map 只濾 deleted。
  /// 兩個母體不一樣不是短暫的不一致，是**穩定殘留**——app bar 永遠寫著
  /// N 孤兒，點進去永遠找不到那些卡。
  ///
  /// 惡化因素在 Hub：取消週期不 cascade 子層，而孤兒自癒的豁免只認
  /// done/cancelled，所以被取消週期底下的 todo 卡會被永久標成孤兒。
  group('🔴 被取消的父層底下那些卡', () {
    test('週期被取消：它底下的卡不進計數', () {
      final h = _snap(
        tasks: [_t('a'), _t('b', checklistId: 'c2')],
        checklists: [_c('c', 'o1'), _c('c2', 'o2')],
        objectives: [_o('o1'), _o('o2', status: 'cancelled')],
      ).entryHint;
      expect(h.label, '0/1');
    });

    test('階段被取消：同理', () {
      final h = _snap(
        tasks: [_t('a'), _t('b', checklistId: 'c2')],
        checklists: [_c('c', 'o1'), _c('c2', 'o1', status: 'cancelled')],
        objectives: [_o('o1')],
      ).entryHint;
      expect(h.label, '0/1');
    });

    test('🔴 孤兒也一樣——這才是那句「N 孤兒卻找不到」的來源', () {
      final h = _snap(
        tasks: [_t('a', claimState: 'orphaned', checklistId: 'c2')],
        checklists: [_c('c2', 'o2')],
        objectives: [_o('o2', status: 'cancelled')],
      ).entryHint;
      expect(h.label, isEmpty, reason: '整塊板沒有一張看得到的卡，入口就該是空的');
    });

    test('父層還在的孤兒照樣要喊', () {
      final h = _snap(
        tasks: [_t('a', claimState: 'orphaned')],
      ).entryHint;
      expect(h.label, '1 孤兒');
    });
  });

  group('可見母體是單一來源', () {
    test('tasksOfObjective 與 visibleTasks 對得起來', () {
      final snap = _snap(
        tasks: [
          _t('a'),
          _t('b', checklistId: 'c2'),
          _t('c3t', checklistId: 'c3'),
        ],
        checklists: [
          _c('c', 'o1'),
          _c('c2', 'o1', status: 'cancelled'),
          _c('c3', 'o2'),
        ],
        objectives: [_o('o1'), _o('o2', status: 'cancelled')],
      );
      expect(snap.tasksOfObjective('o1').map((t) => t.id), ['a']);
      expect(snap.visibleTasks.map((t) => t.id), ['a']);
    });

    test('父層不在快取裡的卡畫不出來，也不該被算到', () {
      // 顯示側從 objective 走下來，父層不在就到不了這張卡；計數側算得到的
      // 話，就是同一個 bug 的另一面
      final snap = BoardSnapshot(tasks: {'x': _t('x')});
      expect(snap.visibleTasks, isEmpty);
    });
  });
}
