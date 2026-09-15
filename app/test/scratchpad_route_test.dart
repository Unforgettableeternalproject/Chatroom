import 'package:chatroom_app/app.dart';
import 'package:chatroom_app/screens/board/scratchpad_screen.dart';
import 'package:flutter_test/flutter_test.dart';

/// 從聊天室點進想法板，人不該被丟到 BOARDS 分頁上。
///
/// `AppShell` 靠路徑參數 `boardId` 決定左欄站在哪一邊，所以「用哪條網址」
/// 就是「左欄跳不跳走」——這不是美觀問題，是使用者按下去之後要自己找路
/// 回來（艾斯維爾 2026-09-03）。
void main() {
  group('padRoute 依進來的軸決定網址', () {
    test('🔴 本次修的 bug：從聊天室進來走房軸，網址裡沒有 boardId 參數', () {
      final r = padRoute(boardId: 'b1', padId: 'p1', roomId: 'r1');
      expect(r, '/rooms/r1/board/pads/p1');
      // 關鍵不在字串長相，而在**它不是 /boards/... 開頭**——
      // 只要是那個開頭，AppShell 就會把左欄切去 BOARDS
      expect(r.startsWith('/boards/'), isFalse);
    });

    test('板軸（Board Library）進來的維持權威路徑', () {
      expect(padRoute(boardId: 'b1', padId: 'p1'), '/boards/b1/pads/p1');
    });
  });

  group('想法板不是訊息流，不抑制通知', () {
    test('房軸的想法板頁 → 不抑制', () {
      expect(activeRoomIdFor('/rooms/r1/board/pads/p1'), isNull);
    });

    test('房軸的板頁本身 → 不抑制', () {
      expect(activeRoomIdFor('/rooms/r1/board'), isNull);
    });
  });
}
