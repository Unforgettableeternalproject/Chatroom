import 'package:chatroom_app/models/board.dart';
import 'package:flutter_test/flutter_test.dart';

/// `moved` 終態的 App 半邊（73fe4d94，Hub `af64961`）。
///
/// 它**不是 done**（在這裡沒有做完），也**不是 cancelled**（不是「不做
/// 了」）——這件事搬到別的地方做了。沒有這個狀態的話，一張早就搬走的卡
/// 會永遠擋著它那份清單送審，而那正是這張卡要解的「收不掉」。
///
/// ⚠️ 重點不是多一個狀態名，是它要在**每一個「已收尾」的判斷**裡都算數。
/// 漏掉任一處的症狀都不同、而且都不報錯。
BoardTask _task(String status, {String movedTo = ''}) =>
    BoardTask.fromJson({
      'id': 't1',
      'checklist_id': 'c1',
      'title': '一張卡',
      'status': status,
      'moved_to': movedTo,
    });

void main() {
  group('moved 是一種收尾', () {
    test('🔴 isSettled 要含 moved——否則它會永遠擋著清單送審', () {
      expect(_task('moved').isSettled, isTrue);
      expect(_task('done').isSettled, isTrue);
      expect(_task('cancelled').isSettled, isTrue);
      expect(_task('todo').isSettled, isFalse);
      expect(_task('blocked').isSettled, isFalse);
    });

    test('🔴 已經搬走的卡不能再被認領', () {
      // 領到一張已經不在這裡的卡，領的人要到打開它才發現
      expect(_task('moved').isClaimable, isFalse);
      expect(_task('todo').isClaimable, isTrue);
    });

    test('搬走的卡在認領軸上算「已收尾」，不是「沒人接」', () {
      expect(_task('moved').axis, ClaimAxis.completed);
    });

    test('moved 不是 done——分子只算真的在這裡做完的', () {
      expect(_task('moved').isDone, isFalse);
    });
  });

  group('離開這份清單的不進分母', () {
    test('🔴 取消與搬走都不算在帳上，done 仍然算', () {
      expect(_task('cancelled').leftThisList, isTrue);
      expect(_task('moved').leftThisList, isTrue);
      // done 是分子，它必須留在分母裡，否則進度條永遠是滿的
      expect(_task('done').leftThisList, isFalse);
      expect(_task('todo').leftThisList, isFalse);
    });

    test('countableTasks 把搬走的排除掉', () {
      final snap = const BoardSnapshot().merge(BoardDelta.fromJson({
        'board_seq': 1,
        'full': true,
        'board_id': 'b1',
        'objectives': [
          {'id': 'o1', 'title': '週期', 'status': 'active'},
        ],
        'checklists': [
          {'id': 'c1', 'objective_id': 'o1', 'title': '階段', 'status': 'open'},
        ],
        'tasks': [
          {'id': 't1', 'checklist_id': 'c1', 'title': '做完的', 'status': 'done'},
          {'id': 't2', 'checklist_id': 'c1', 'title': '搬走的', 'status': 'moved'},
          {'id': 't3', 'checklist_id': 'c1', 'title': '還在做', 'status': 'todo'},
        ],
      }));
      expect(snap.countableTasks.map((t) => t.id), ['t1', 't3']);
    });
  });

  group('去向', () {
    test('moved_to 讀得到；沒說去向時是空字串不是 null', () {
      // Hub 那邊 `moved_to` 是選填——「搬走了但沒說去哪」是合法狀態，
      // 畫面不該因此崩或顯示 null
      expect(_task('moved', movedTo: 't99').movedTo, 't99');
      expect(_task('moved').movedTo, isEmpty);
    });
  });

  group('按鈕', () {
    test('🔴 三個未收尾狀態都要有「搬到別處」', () {
      for (final from in ['todo', 'in_progress', 'blocked']) {
        expect(taskActionsFor(from).map((a) => a.target), contains('moved'),
            reason: '$from 少了搬走的出口');
      }
    });

    test('搬錯了收得回來——與 cancelled 對稱', () {
      expect(taskActionsFor('moved').map((a) => a.target), ['todo']);
    });

    test('收尾了的不能橫向改成另一種收尾', () {
      expect(taskActionsFor('done').map((a) => a.target), isNot(contains('moved')));
      expect(
          taskActionsFor('cancelled').map((a) => a.target), isNot(contains('moved')));
    });
  });
}
