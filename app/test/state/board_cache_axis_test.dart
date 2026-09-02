import 'package:chatroom_app/models/board.dart';
import 'package:chatroom_app/state/board_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Board 快取的軸：**boardId，不是 roomId**。
///
/// v2 起一塊 Board 可以掛在多間房。以房為 key 的話同一塊板會存成兩份、
/// 各自推各自的水位——不會報錯，但兩間房看到的板會漸行漸遠，而且是慢慢的，
/// 沒有任何一刻看起來像壞掉。

BoardDelta _delta({
  required int seq,
  String boardId = 'b1',
  bool full = false,
  List<Map<String, dynamic>> tasks = const [],
}) =>
    BoardDelta.fromJson({
      'board_seq': seq,
      'board_id': boardId,
      'full': full,
      'tasks': tasks,
    });

Map<String, dynamic> _task(String id) => {
  'id': id,
  'room_id': 'r1',
  'checklist_id': 'c1',
  'title': id,
  'status': 'todo',
  'deleted': false,
  'board_seq': 1,
  'created_at': '2026-09-02T00:00:00Z',
};

BoardCache _cache() {
  final container = ProviderContainer();
  addTearDown(container.dispose);
  return container.read(boardCacheProvider.notifier);
}

void main() {
  test('兩間房掛同一塊板，共用一份快取與一個水位', () {
    final cache = _cache();
    cache.apply('b1', _delta(seq: 3, full: true, tasks: [_task('t1')]),
        roomId: 'roomA');

    // 從另一間房進來——**不可以是新的一份**。是的話 roomB 會從水位 0 重拉，
    // 而兩份會各自往前走
    expect(cache.snapshotForRoom('roomB').boardSeq, 0); // 還沒學到對應
    cache.apply('b1', _delta(seq: 4), roomId: 'roomB');

    expect(cache.boardIdOf('roomA'), 'b1');
    expect(cache.boardIdOf('roomB'), 'b1');
    expect(cache.snapshotForRoom('roomA').boardSeq, 4);
    expect(cache.snapshotForRoom('roomB').boardSeq, 4);
    // 同一份：roomA 先放進去的卡，roomB 這邊看得到
    expect(cache.snapshotForRoom('roomB').tasks.containsKey('t1'), isTrue);
  });

  test('對應從回應學來，不必為了解析多打一次 API', () {
    final cache = _cache();
    expect(cache.boardIdOf('roomA'), isNull);
    // 第一次拉取時呼叫端還不知道 boardId，只能先用 roomId 當暫時的 key；
    // 回應裡的 board_id 要蓋過它，否則快取會留在錯誤的軸上
    cache.apply('roomA', _delta(seq: 1, boardId: 'b9', full: true),
        roomId: 'roomA');
    expect(cache.boardIdOf('roomA'), 'b9');
    expect(cache.snapshotOf('b9').boardSeq, 1);
    expect(cache.snapshotOf('roomA').boardSeq, 0);
  });

  test('舊 Hub 不回 board_id 時退回以房為 key，不是丟掉', () {
    // 遷移期間兩種 Hub 並存。拿不到 board_id 就當機或不存的話，
    // 舊 Hub 那邊的板會整個讀不出來
    final cache = _cache();
    cache.apply('roomA', BoardDelta.fromJson({'board_seq': 2, 'full': true}),
        roomId: 'roomA');
    expect(cache.snapshotForRoom('roomA').boardSeq, 2);
  });

  test('離開房間只解除對應，不丟板的快取', () {
    // 那塊板可能還掛在別的房、或正開在 Board Library 裡。
    // 跟著房一起丟掉的話，另一個畫面的水位會無聲地倒退成 0，
    // 然後用一個過期的水位去要增量——那段期間被刪掉的卡就永遠留著了
    final cache = _cache();
    cache.apply('b1', _delta(seq: 5, full: true), roomId: 'roomA');
    cache.apply('b1', _delta(seq: 5), roomId: 'roomB');

    cache.forgetRoom('roomA');

    expect(cache.boardIdOf('roomA'), isNull);
    expect(cache.snapshotOf('b1').boardSeq, 5);
    expect(cache.snapshotForRoom('roomB').boardSeq, 5);
  });
}
