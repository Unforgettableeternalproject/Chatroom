import 'package:chatroom_app/models/board.dart';
import 'package:flutter_test/flutter_test.dart';

/// 聊天室 app bar 上 Board 入口的四種狀態（設計稿 artboard 06）。
///
/// 規則：**只有「等你確認」點亮**——那是唯一需要人動手、而且只有人能動的事。
/// 有進度、有孤兒都只是資訊。每個按鈕都在喊的話，就沒有一個在喊了。
///
/// 測的是 [BoardSnapshot.entryHint] 本人，不是它在 widget 裡的副本——
/// 複製一份判斷來測，測到的只會是那份副本自己。
BoardSnapshot _snap({
  List<BoardTask> tasks = const [],
  List<BoardObjective> objectives = const [],
}) =>
    BoardSnapshot(
      tasks: {for (final t in tasks) t.id: t},
      objectives: {for (final o in objectives) o.id: o},
    );

BoardTask _t(String id,
        {String status = 'todo',
        String claimState = '',
        bool deleted = false}) =>
    BoardTask(
      id: id,
      roomId: 'r',
      checklistId: 'c',
      title: id,
      boardSeq: 1,
      status: status,
      claimState: claimState,
      deleted: deleted,
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

  test('verified 不算「等你確認」——那一步 agent 自己按得動', () {
    final h = _snap(
      tasks: [_t('a')],
      objectives: [_o('o1', status: 'verified')],
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
}
