import 'package:chatroom_app/models/board.dart';
import 'package:chatroom_app/screens/board/board_dependency_picker.dart';
import 'package:flutter_test/flutter_test.dart';

/// 任務卡依賴／影響（v1.2.8-hotfix1）的模型層。
///
/// 重點有兩個：缺欄位（舊 Hub）要當空，不能炸；顯示狀態要以 App 手上那張卡的
/// **最新資料**為準，Hub 回的 status 是讀取當下的快照。
Map<String, dynamic> _task(String id, {Map<String, dynamic>? extra, String status = 'todo', String? movedTo}) => {
      'id': id,
      'checklist_id': 'c1',
      'title': '卡 $id',
      'status': status,
      'moved_to': ?movedTo,
      ...?extra,
    };

BoardSnapshot _snap(List<Map<String, dynamic>> tasks) =>
    const BoardSnapshot().merge(BoardDelta.fromJson({
      'board_seq': 1,
      'full': true,
      'board_id': 'b1',
      'objectives': [
        {'id': 'o1', 'title': '週期'}
      ],
      'checklists': [
        {'id': 'c1', 'objective_id': 'o1', 'title': '階段'}
      ],
      'tasks': tasks,
    }));

void main() {
  group('BoardTask.fromJson 的依賴欄位', () {
    test('🔴 舊 Hub 沒有這些欄位：全部視為空 / false，不炸', () {
      final t = BoardTask.fromJson(_task('t1'));
      expect(t.dependsOn, isEmpty);
      expect(t.affects, isEmpty);
      expect(t.unmet, isEmpty);
      expect(t.dependencyBlocked, isFalse);
      expect(t.blockedByDependency, isFalse);
      expect(t.isDependencyLocked, isFalse);
    });

    test('解析 depends_on / affects / unmet / 兩個旗標', () {
      final t = BoardTask.fromJson(_task('t1', extra: {
        'depends_on': [
          {
            'id': 'a',
            'title': '依賴 A',
            'status': 'in_progress',
            'moved_to': '',
            'met': false,
            'cancelled': false,
            'via': '',
          },
          {
            'id': 'b',
            'title': '依賴 B',
            'status': 'moved',
            'moved_to': 'c',
            'met': true,
            'cancelled': false,
            'via': 'c',
          },
        ],
        'affects': [
          {'id': 'x', 'title': '被影響 X', 'status': 'todo'}
        ],
        'unmet': [
          {'id': 'a', 'title': '依賴 A', 'status': 'in_progress', 'met': false}
        ],
        'dependency_blocked': true,
        'blocked_by_dependency': false,
      }));
      expect(t.dependsOn.map((d) => d.id), ['a', 'b']);
      expect(t.dependsOn[1].via, 'c');
      expect(t.dependsOn[1].met, isTrue);
      expect(t.affects.single.title, '被影響 X');
      expect(t.unmet.single.id, 'a');
      expect(t.dependencyBlocked, isTrue);
      expect(t.isDependencyLocked, isTrue);
    });

    test('依賴造成的卡住也算被鎖住', () {
      final t = BoardTask.fromJson(_task('t1',
          status: 'blocked', extra: {'blocked_by_dependency': true}));
      expect(t.blockedByDependency, isTrue);
      expect(t.isDependencyLocked, isTrue);
    });
  });

  group('blocksTransitionTo：被擋住時哪些轉移按不得', () {
    test('阻擋中的待辦卡：不能開始、不能完成；可以卡住 / 取消 / 搬走', () {
      final t = BoardTask.fromJson(
          _task('t1', extra: {'dependency_blocked': true}));
      expect(t.blocksTransitionTo('in_progress'), isTrue);
      expect(t.blocksTransitionTo('done'), isTrue);
      expect(t.blocksTransitionTo('blocked'), isFalse);
      expect(t.blocksTransitionTo('cancelled'), isFalse);
      expect(t.blocksTransitionTo('moved'), isFalse);
    });

    test('依賴造成的卡住：不能手動推回進行中', () {
      final t = BoardTask.fromJson(_task('t1',
          status: 'blocked', extra: {'blocked_by_dependency': true}));
      expect(t.blocksTransitionTo('in_progress'), isTrue);
    });

    test('沒被擋的卡不受影響', () {
      final t = BoardTask.fromJson(_task('t1'));
      expect(t.blocksTransitionTo('in_progress'), isFalse);
      expect(t.blocksTransitionTo('done'), isFalse);
    });
  });

  group('DependencyChange', () {
    test('解析 dependency_changes；缺欄位 / 型別不對視為空', () {
      final list = DependencyChange.listFrom([
        {
          'id': 'a',
          'title': 'A',
          'from': 'in_progress',
          'to': 'blocked',
          'reason': 'dependency_unmet'
        },
        {'id': 'b', 'reason': 'dependency_met'},
      ]);
      expect(list.length, 2);
      expect(list[0].isAutoBlocked, isTrue);
      expect(list[1].isAutoResumed, isTrue);
      expect(DependencyChange.listFrom(null), isEmpty);
      expect(DependencyChange.listFrom('壞資料'), isEmpty);
    });
  });

  group('dependencyView：以手上最新資料為準', () {
    TaskDependency dep(String id,
            {String status = 'todo',
            bool met = false,
            String via = '',
            String movedTo = ''}) =>
        TaskDependency(
            id: id, status: status, met: met, via: via, movedTo: movedTo);

    test('🔴 快照說還沒做完，但手上那張已經完成 ⇒ 已完成', () {
      final snap = _snap([_task('a', status: 'done')]);
      final v = dependencyView(dep('a', status: 'in_progress'), (id) => snap.tasks[id]);
      expect(v.state, DependencyState.done);
      expect(v.met, isTrue);
    });

    test('查不到那張卡才用快照', () {
      final v = dependencyView(dep('zzz', status: 'in_progress'), (_) => null);
      expect(v.state, DependencyState.unmet);
      expect(v.met, isFalse);
      final v2 = dependencyView(dep('zzz', status: 'done'), (_) => null);
      expect(v2.state, DependencyState.done);
    });

    test('已取消 ⇒ 視為解除但標示', () {
      final snap = _snap([_task('a', status: 'cancelled')]);
      final v = dependencyView(dep('a'), (id) => snap.tasks[id]);
      expect(v.state, DependencyState.cancelled);
      expect(v.met, isTrue);
    });

    test('搬走且有去向 ⇒ 跟隨到去向那張，滿足與否看它', () {
      final snap = _snap([
        _task('a', status: 'moved', movedTo: 'b'),
        _task('b', status: 'in_progress'),
      ]);
      final v = dependencyView(dep('a', status: 'moved', via: 'b'), (id) => snap.tasks[id]);
      expect(v.state, DependencyState.movedFollowing);
      expect(v.targetTitle, '卡 b');
      expect(v.met, isFalse);

      final done = _snap([
        _task('a', status: 'moved', movedTo: 'b'),
        _task('b', status: 'done'),
      ]);
      expect(
          dependencyView(dep('a', status: 'moved', via: 'b'), (id) => done.tasks[id])
              .met,
          isTrue);
    });

    test('搬走沒寫去向 ⇒ 未滿足', () {
      final snap = _snap([_task('a', status: 'moved')]);
      final v = dependencyView(dep('a', status: 'moved'), (id) => snap.tasks[id]);
      expect(v.state, DependencyState.movedBlank);
      expect(v.met, isFalse);
    });

    test('搬走的鏈壞成環不會無限迴圈', () {
      final snap = _snap([
        _task('a', status: 'moved', movedTo: 'b'),
        _task('b', status: 'moved', movedTo: 'a'),
      ]);
      final v = dependencyView(dep('a', status: 'moved', via: 'b'), (id) => snap.tasks[id]);
      expect(v.state, DependencyState.movedFollowing);
    });
  });

  group('依賴／影響的候選', () {
    test('排除自己、已刪除、已取消、已搬走', () {
      final snap = _snap([
        _task('me'),
        _task('ok'),
        _task('gone', extra: {'deleted': true}),
        _task('cancelled', status: 'cancelled'),
        _task('moved', status: 'moved'),
        _task('done', status: 'done'),
      ]);
      final ids =
          dependencyCandidates(snap, excludeId: 'me').map((c) => c.taskId);
      expect(ids.toSet(), {'ok', 'done'});
    });

    test('sameIdSet 不看順序', () {
      expect(sameIdSet(['a', 'b'], ['b', 'a']), isTrue);
      expect(sameIdSet(['a'], ['a', 'b']), isFalse);
      expect(sameIdSet([], []), isTrue);
    });
  });
}
