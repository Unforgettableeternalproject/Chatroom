import 'package:chatroom_app/api/board_api.dart';
import 'package:chatroom_app/models/board.dart';
import 'package:chatroom_app/state/board_providers.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// 🔴 2026-09-03：**在 09/03 房點進板，看到的是 09/02 房的卡。**
///
/// 兩個各自成立的設計湊在一起壞掉：
///
///   - 快取以 **board_id** 為 key（v2 刻意：兩條路徑進到同一塊板要看到同一份）
///   - 房軸的 delta **只含這間房的卡**
///
/// ⇒ 從 A 房進板把共用快照的水位推到最新；切到 B 房時沿用那個水位去要增量，
/// Hub 只回該水位之後的變動，**B 房自己的卡一張都不會來**，畫面上留著 A 房
/// 的內容。沒有錯誤、沒有空白——看起來就像「這個房的卡不見了」。
///
/// 這條測試守的是**那個組合**，不是只守「有沒有帶 0」。
class _RoomScopedApi extends BoardApi {
  _RoomScopedApi() : super(Dio());

  /// 每個房各自的卡，模擬 Hub 的房軸子集行為。
  static const _byRoom = {
    'roomA': ('A 房的週期', 'a1', 200),
    'roomB': ('B 房的週期', 'b1', 120),
  };

  /// 每次請求帶的 after_board_seq，讓測試看得到「有沒有拿快取水位去要增量」。
  final List<int> seenAfter = [];

  @override
  Future<BoardDelta> fetch(String roomId,
      {int afterBoardSeq = 0, String? participantId}) async {
    seenAfter.add(afterBoardSeq);
    final (title, oid, seq) = _byRoom[roomId]!;
    // Hub 的實際行為：帶了水位就只回該水位之後的東西。這裡照做——
    // 房軸若沿用另一間房推高的水位，回來的就是一份空的增量
    if (afterBoardSeq >= seq) {
      return BoardDelta.fromJson({
        'board_seq': 263,
        'full': false,
        'board_id': 'sharedBoard',
        'objectives': [],
        'tasks': [],
      });
    }
    return BoardDelta.fromJson({
      'board_seq': seq,
      'full': afterBoardSeq == 0,
      'board_id': 'sharedBoard',
      'objectives': [
        {'id': oid, 'title': title, 'board_seq': seq},
      ],
      'tasks': [
        {'id': '$oid-t', 'checklist_id': 'c', 'title': '$title 的卡'},
      ],
    });
  }
}

ProviderContainer _container(_RoomScopedApi api) => ProviderContainer(
      overrides: [
        boardApiProvider.overrideWithValue(api),
        // 身分不是這條測試的主題，直接給一個
        boardParticipantIdProvider.overrideWith((ref, roomId) async => 'p1'),
        // WS 水位訊號：不推任何東西
        boardSignalProvider.overrideWith((ref, roomId) => const Stream.empty()),
      ],
    );

void main() {
  test('🔴 A 房把水位推高之後，切到 B 房仍然看得到 B 房的卡', () async {
    final api = _RoomScopedApi();
    final c = _container(api);
    addTearDown(c.dispose);

    // ⚠️ 順序要照實際踩到的那條路：**先進過 B 房**，快取才記得
    // 「B 房 → 這塊板」的對應。第一次進一間新房時對應還不存在，
    // 拿到的是空快照、水位 0——所以第一次永遠是對的，第二次才會壞
    final first = await c.read(boardProvider('roomB').future);
    expect(first.sortedObjectives.single.title, 'B 房的週期');

    // 切去 A 房：同一份共用快照被 A 房的內容覆寫，水位推到 200
    final a = await c.read(boardProvider('roomA').future);
    expect(a.sortedObjectives.single.title, 'A 房的週期');

    // 再切回 B 房。這一次快取已經有對應了 ⇒ 舊行為會拿 A 房推高的水位
    c.invalidate(boardProvider('roomB'));
    final b = await c.read(boardProvider('roomB').future);
    expect(
      b.sortedObjectives.map((o) => o.title),
      contains('B 房的週期'),
      reason: '沿用 A 房推高的水位時，這裡會是 A 房的週期——那正是回報的症狀',
    );
  });

  test('房軸一律帶 after_board_seq=0——水位不跨房沿用', () async {
    final api = _RoomScopedApi();
    final c = _container(api);
    addTearDown(c.dispose);

    await c.read(boardProvider('roomB').future);
    await c.read(boardProvider('roomA').future);
    c.invalidate(boardProvider('roomB'));
    await c.read(boardProvider('roomB').future);

    expect(api.seenAfter, everyElement(0));
  });
}
