import 'package:chatroom_app/models/board.dart';
import 'package:flutter_test/flutter_test.dart';

/// 房軸回應的 `attached_rooms`（Hub `fac2ff3`，2026-09-04）。
///
/// 🔴 少了它的症狀是艾斯維爾想法板觀察 ①：**從聊天室進板，徽章寫「未掛接
/// 聊天室」**——而板明明就掛在他正看著的那間房上。成因不是條件寫錯，是
/// **房軸從來沒回過這份資料**，`liveRooms` 恆空，於是那句話換了個路徑照樣
/// 說得出口。
///
/// ⚠️ 這條測的是**契約**，不是 UI 行為：Hub 那側是新寫的欄位、UI 這側是
/// 早就存在的解析，兩邊都「自己看起來沒問題」。我當時說「UI 一個字都不用
/// 改」是讀碼比對出來的結論——比對是會過期的，所以把它變成一條會紅的測試。
///
/// 形狀取自 Hub `_attached_rooms()` 的實際輸出（房軸與板軸共用同一份）。
Map<String, dynamic> _hubShape() => {
      'board_seq': 300,
      'full': true,
      'board_id': 'bd1',
      'objectives': const [],
      'tasks': const [],
      'attached_rooms': [
        {
          'id': 'r1',
          'name': '09/03 需求落地',
          'status': 'active',
          'visibility': 'private',
          'detached': false,
          'supervisor': {
            'actor_key': 'claude-abc',
            'display_name': '裁定Novia',
            'actor_kind': 'claude',
            'departed': false,
          },
        },
        {
          'id': 'r2',
          'name': '已經解除的房',
          'status': 'active',
          'visibility': 'public',
          'detached': true,
          'supervisor': null,
        },
        {
          'id': 'r3',
          'name': '監察者走了的房',
          'status': 'archived',
          'visibility': 'public',
          'detached': false,
          'supervisor': {
            'actor_key': 'claude-gone',
            'display_name': '某人',
            'actor_kind': 'claude',
            'departed': true,
          },
        },
      ],
    };

BoardSnapshot _snap() =>
    const BoardSnapshot().merge(BoardDelta.fromJson(_hubShape()));

void main() {
  test('🔴 房軸的 attached_rooms 進得了快照——徽章的數字就是它', () {
    final rooms = _snap().liveRooms.toList();
    // 解除的那間不算「現在掛著」，封存的那間仍然算
    expect(rooms.map((r) => r.id), ['r1', 'r3']);
  });

  test('🔴 已解除的房留在快照裡並標明——「解除了」與「從來沒掛過」不一樣', () {
    // 這裡本來會是 null：merge 把 detached 當 tombstone 移除，於是
    // `_showAttachedRooms` 那段「已解除」的標示永遠不會亮（死碼）。
    // 擋殘留是 `liveRooms` 的事，不必用丟掉歷史來換
    expect(_snap().attachedRooms['r2']?.detached, isTrue);
  });

  test('supervisor 是 per-room 的，跟著各自的房走', () {
    final s = _snap();
    expect(s.attachedRooms['r1']!.supervisor!.displayName, '裁定Novia');
    expect(s.attachedRooms['r2']!.supervisor, isNull);
  });

  test('🔴 「他走了」與「沒有人」是兩種狀態，不可以塌成同一個', () {
    // 退場是標記不是清空：名字還在，departed 才是那個差別
    final r3 = _snap().attachedRooms['r3']!;
    expect(r3.supervisor, isNotNull);
    expect(r3.supervisorDeparted, isTrue);
    expect(_snap().attachedRooms['r1']!.supervisorDeparted, isFalse);
  });

  test('沒有這個欄位時是空的，不是炸掉——舊 Hub 仍要能連', () {
    final old = Map<String, dynamic>.from(_hubShape())..remove('attached_rooms');
    expect(
      const BoardSnapshot().merge(BoardDelta.fromJson(old)).liveRooms,
      isEmpty,
    );
  });
}
