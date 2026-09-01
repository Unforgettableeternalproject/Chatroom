import 'package:chatroom_app/models/ws_event.dart';
import 'package:chatroom_app/ws/ws_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

/// WS 的 board 事件（三層裡的第一、二層在 App 這側的接點）。
///
/// 🔴 **它必須是獨立事件型別，不能夾在 `messages` 那包裡。**
/// board 最常見的變動（建卡、認領、改狀態）**一則訊息都不發**（設計文件
/// §4.3），夾帶的話水位只有在「剛好同時有人講話」時才捎得出去——而那是最
/// 不需要它的時候。同一個坑 `/updates` 踩過一次，退化量測是 1.3 秒 → 12 秒。
void main() {
  test('board 事件解得出房間與水位', () {
    final e = WsProtocol.decode(
        '{"type":"board","room_id":"r1","board_seq":42}');

    expect(e, isA<WsBoardEvent>());
    e as WsBoardEvent;
    expect(e.roomId, 'r1');
    expect(e.boardSeq, 42);
  });

  test('🔴 board 事件不帶內容——WS 只負責喚醒，不當第二個真相來源', () {
    // 這條防的是「順手把 tasks 塞進推播」：那樣 WS 與 GET /board 會各自
    // 演化成兩份真相，而它們不同步時沒有任何地方會報錯。
    final e = WsProtocol.decode(
        '{"type":"board","room_id":"r1","board_seq":42,"tasks":[{"id":"x"}]}');

    expect(e, isA<WsBoardEvent>());
    // 型別上就沒有存內容的地方，多送的欄位被丟掉
    expect((e as WsBoardEvent).boardSeq, 42);
  });

  test('缺欄位的 board 事件退化成 0，不炸掉整條連線', () {
    final e = WsProtocol.decode('{"type":"board"}') as WsBoardEvent;
    expect(e.roomId, '');
    expect(e.boardSeq, 0);
  });

  test('舊 Hub 沒有 board 事件時，其他事件照常解析', () {
    expect(WsProtocol.decode('{"type":"pong"}'), isA<WsPongEvent>());
    expect(WsProtocol.decode('{"type":"whatever"}'), isA<WsUnknownEvent>());
  });
}
