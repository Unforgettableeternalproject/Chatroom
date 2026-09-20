import 'package:chatroom_app/models/room.dart';
import 'package:flutter_test/flutter_test.dart';

/// 工作房的**一次性工作區綁定**（`workspace_key` / `workspace_served`）。
///
/// 🔴 **缺鍵一律「還沒綁」「沒人服務」。** 舊 Hub 不回這兩個欄位，而猜錯的
/// 兩種結果都會在畫面上變成一句假話：猜出一個 key 會讓頁首寫「只能派工到
/// X」而 Hub 其實誰都收；猜 `served=true` 會把派工入口畫出來，而那顆按鈕
/// 送出去的單沒有人領。
void main() {
  Map<String, dynamic> base(Map<String, dynamic> extra) => {
        'id': 'r1',
        'name': '遠端派工',
        'kind': 'ops',
        'created_at': '2026-09-16T00:00:00+00:00',
        ...extra,
      };

  test('Hub 回了 key 與 served，兩個都照收', () {
    final room = Room.fromJson(base({
      'workspace_key': 'ai-website',
      'workspace_served': true,
    }));
    expect(room.workspaceKey, 'ai-website');
    expect(room.workspaceServed, isTrue);
    expect(room.hasWorkspace, isTrue);
    expect(room.canDispatchRuns, isTrue);
  });

  test('舊 Hub 沒有這兩個欄位：還沒綁、沒人服務', () {
    final room = Room.fromJson(base(const {}));
    expect(room.workspaceKey, isNull);
    expect(room.workspaceServed, isFalse);
    expect(room.hasWorkspace, isFalse);
    // 派工入口不出現。畫出來就是一顆 409 `workspace_not_bound`
    expect(room.canDispatchRuns, isFalse);
  });

  test('null 與空字串都是「還沒綁」——不能讓畫面說出「只能派工到「」」', () {
    expect(Room.fromJson(base(const {'workspace_key': null})).workspaceKey,
        isNull);
    expect(Room.fromJson(base(const {'workspace_key': '   '})).hasWorkspace,
        isFalse);
  });

  test('綁了但現在沒有執行器服務它：派不出工，但要知道綁在哪', () {
    final room = Room.fromJson(base({
      'workspace_key': 'ai-website',
      'workspace_served': false,
    }));
    expect(room.hasWorkspace, isTrue);
    // 「綁在哪」與「現在有沒有人做」是兩件事，畫面上也要是兩句話
    expect(room.canDispatchRuns, isFalse);
  });

  test('非工作房就算有這兩個欄位也派不出工', () {
    final room = Room.fromJson({
      'id': 'r1',
      'name': '一般房',
      'created_at': '2026-09-16T00:00:00+00:00',
      'workspace_key': 'ai-website',
      'workspace_served': true,
    });
    expect(room.canDispatchRuns, isFalse);
  });

  test('copyWith 不會把綁定弄丟——列表更新一次就變回未綁的話，'
      '頁首那行字會在眼前消失', () {
    final room = Room.fromJson(base({
      'workspace_key': 'ai-website',
      'workspace_served': true,
    }));
    final updated = room.copyWith(memberCount: 3);
    expect(updated.workspaceKey, 'ai-website');
    expect(updated.workspaceServed, isTrue);
  });
}
