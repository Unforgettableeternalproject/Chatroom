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
/// ## 止血與根治
///
/// 當時的止血是**房軸一律要全量**（`afterBoardSeq: 0`），代價是每次進房都
/// 重拉整塊板。根治在 Hub `0876746`：**房軸回的是整塊板**，不再只回這間房
/// 的卡——兩軸語意對齊之後，共用快照與共用水位就不再矛盾。
///
/// 2026-09-05 撤掉止血，這個檔案跟著**換它守的東西**：
///
///   - 舊：「房軸一律帶 0」——那是止血本身，止血撤了它就沒有意義
///   - 新：「切房不會漏卡」＋「水位真的被沿用了」
///
/// 前者是這條測試從頭到尾的目標，後者確保止血真的撤乾淨（留著等於白撤）。
///
/// ⚠️ mock 也跟著換成新契約：房軸回整塊板。**照舊契約寫的 mock 會讓撤止血
/// 之後的程式碼看起來是壞的**，而真正壞掉的是那份 mock 描述的世界已經不在。
/// 依據是除錯端 2026-09-05 在 8788 打真 HTTP 的實測（不是 in-process）：
/// A 房全量回兩間房的卡、B 房帶水位的增量正確地回空。
class _WholeBoardApi extends BoardApi {
  _WholeBoardApi() : super(Dio());

  /// 這塊板上的東西，**不分房**——Hub `0876746` 之後房軸回的就是整塊板。
  /// 每一筆帶自己的 board_seq，增量照水位過濾。
  static const _items = [
    ('a1', 'A 房建的週期', 100),
    ('b1', 'B 房建的週期', 120),
  ];

  static const _head = 120;

  /// 每次請求帶的 after_board_seq。**這條測試的分界線**：止血撤掉之前
  /// 它永遠是 0。
  final List<int> seenAfter = [];

  @override
  Future<BoardDelta> fetch(String roomId,
      {int afterBoardSeq = 0, String? participantId}) async {
    seenAfter.add(afterBoardSeq);
    final fresh = [
      for (final (id, title, seq) in _items)
        if (seq > afterBoardSeq)
          {'id': id, 'title': title, 'board_seq': seq},
    ];
    return BoardDelta.fromJson({
      'board_seq': _head,
      'full': afterBoardSeq == 0,
      'board_id': 'sharedBoard',
      'objectives': fresh,
      'tasks': const [],
    });
  }
}

ProviderContainer _container(_WholeBoardApi api) => ProviderContainer(
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
    final api = _WholeBoardApi();
    final c = _container(api);
    addTearDown(c.dispose);

    // ⚠️ 順序要照實際踩到的那條路：**先進過 B 房**，快取才記得
    // 「B 房 → 這塊板」的對應。第一次進一間新房時對應還不存在，
    // 拿到的是空快照、水位 0——所以第一次永遠是對的，第二次才會壞
    final first = await c.read(boardProvider('roomB').future);
    expect(first.sortedObjectives.map((o) => o.id), contains('b1'));

    // 切去 A 房：同一份共用快照，水位已經在 120
    await c.read(boardProvider('roomA').future);

    // 再切回 B 房。這一次快取已經有對應、水位也被推上去了
    c.invalidate(boardProvider('roomB'));
    final b = await c.read(boardProvider('roomB').future);
    expect(
      b.sortedObjectives.map((o) => o.id),
      containsAll(['a1', 'b1']),
      reason: '房軸回的是整塊板 ⇒ 切回來時兩房的東西都還在。'
          '這裡少了 b1 就是當初回報的症狀',
    );
  });

  test('🔴 止血撤掉了：水位真的被沿用，不再每次重拉全量', () async {
    final api = _WholeBoardApi();
    final c = _container(api);
    addTearDown(c.dispose);

    await c.read(boardProvider('roomB').future);
    await c.read(boardProvider('roomA').future);
    c.invalidate(boardProvider('roomB'));
    await c.read(boardProvider('roomB').future);

    // ⚠️ **每間房第一次進去都會全量**，而且那是對的：`_boardIdByRoom` 的
    // 對應是在第一次回應裡才建立的，在那之前 client 不知道這間房對到哪塊
    // 板，`snapshotForRoom` 只能回空快照（水位 0）。
    //
    // 所以前兩次（B 第一次、A 第一次）帶 0 是正常的，分界線在**第三次**
    // ——那時 B 房的對應已經有了。
    expect(api.seenAfter.take(2), everyElement(0),
        reason: '兩間房各自的第一次都還沒有對應，全量是對的');
    expect(
      api.seenAfter.last,
      greaterThan(0),
      reason: '止血（一律帶 0）撤掉之後，對應已知的房要帶快取水位。'
          '這裡還是 0 就是止血沒撤乾淨——而畫面看起來完全正常',
    );
  });

  test('空板重拉全量，不會拿著高水位空等', () async {
    // `resumeFrom` 在手上沒有任何卡時回 0。真的空板重拉一次全量是免費的
    // （回來還是空的）；而拿著高水位空等，畫面會**永遠**是空的且不報錯
    expect(const BoardSnapshot(boardSeq: 999).resumeFrom, 0);
  });
}
