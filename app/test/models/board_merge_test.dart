import 'package:chatroom_app/models/board.dart';
import 'package:flutter_test/flutter_test.dart';

/// Board 增量合併。三種變更（新增／修改／刪除）都要正確套進本機快取。
///
/// 刪除那條是重點：Hub **會把軟刪除的列照樣回傳**（帶 `deleted: true`），
/// 那是 tombstone。當成一般資料塞進去，board 上就留著一張不存在的卡；
/// 直接忽略，那張卡同樣不會消失。
Map<String, dynamic> _task(String id, {
  int seq = 1,
  String title = 'T',
  bool deleted = false,
  String claimState = '',
  String status = 'todo',
  int order = 0,
}) =>
    {
      'id': id,
      'room_id': 'r1',
      'checklist_id': 'c1',
      'title': title,
      'status': status,
      'order_index': order,
      'claim_state': claimState,
      'claim_name': claimState.isEmpty ? '' : 'Novia',
      'deleted': deleted,
      'board_seq': seq,
      'created_at': '2026-09-01T00:00:0${order}Z',
    };

BoardDelta _delta(int seq, List<Map<String, dynamic>> tasks,
        {bool full = false}) =>
    BoardDelta.fromJson({
      'board_seq': seq,
      'full': full,
      'tasks': tasks,
    });

void main() {
  test('新增：全量回應把列建進快取', () {
    final s = const BoardSnapshot().merge(
      _delta(2, [_task('t1'), _task('t2', seq: 2)], full: true),
    );
    expect(s.tasks.keys, containsAll(['t1', 't2']));
    expect(s.boardSeq, 2);
  });

  test('修改：同一個 id 直接覆蓋，不是合併欄位', () {
    var s = const BoardSnapshot().merge(_delta(1, [_task('t1')], full: true));
    s = s.merge(_delta(5, [_task('t1', seq: 5, title: '改過', claimState: 'held')]));

    expect(s.tasks.length, 1);
    expect(s.tasks['t1']!.title, '改過');
    expect(s.tasks['t1']!.isHeld, isTrue);
    expect(s.boardSeq, 5);
  });

  test('刪除：tombstone 要把卡從快取移除，不是留著也不是忽略', () {
    var s = const BoardSnapshot()
        .merge(_delta(1, [_task('t1'), _task('t2', seq: 1)], full: true));
    s = s.merge(_delta(7, [_task('t1', seq: 7, deleted: true)]));

    expect(s.tasks.containsKey('t1'), isFalse, reason: 'tombstone 沒被移除');
    expect(s.tasks.containsKey('t2'), isTrue, reason: '不該波及其他列');
  });

  test('全量回應整份取代——上一輪存在、這次沒回的列不可以留著', () {
    var s = const BoardSnapshot()
        .merge(_delta(1, [_task('t1'), _task('t2', seq: 1)], full: true));
    s = s.merge(_delta(9, [_task('t1', seq: 9)], full: true));

    expect(s.tasks.keys, ['t1']);
  });

  test('增量回應是疊加，沒提到的列留著', () {
    var s = const BoardSnapshot()
        .merge(_delta(1, [_task('t1'), _task('t2', seq: 1)], full: true));
    s = s.merge(_delta(4, [_task('t1', seq: 4, title: '只動這張')]));

    expect(s.tasks.length, 2);
    expect(s.tasks['t2']!.title, 'T');
  });

  test('水位只進不退——倒退會讓下一次重拉已經套用過的東西', () {
    var s = const BoardSnapshot().merge(_delta(10, [_task('t1', seq: 10)]));
    s = s.merge(_delta(3, const []));
    expect(s.boardSeq, 10);
  });

  test('orphaned 仍可被認領，done 與 cancelled 不行', () {
    final s = const BoardSnapshot().merge(_delta(
      1,
      [
        _task('free'),
        _task('held', claimState: 'held'),
        _task('orphan', claimState: 'orphaned'),
        _task('done', status: 'done'),
      ],
      full: true,
    ));

    expect(s.tasks['free']!.isClaimable, isTrue);
    expect(s.tasks['held']!.isClaimable, isFalse);
    expect(s.tasks['orphan']!.isClaimable, isTrue,
        reason: '持有者已經不在房內，就不算「同時」被兩個人領走');
    expect(s.tasks['done']!.isClaimable, isFalse);
  });

  test('排序依 order_index，同序時用 created_at 決勝', () {
    final s = const BoardSnapshot().merge(_delta(
      1,
      [
        _task('b', order: 1),
        _task('a', order: 0),
        _task('c', order: 1),
      ],
      full: true,
    ));

    expect(s.tasksOf('c1').map((t) => t.id).toList(), ['a', 'b', 'c']);
  });
}
