import 'package:chatroom_app/models/board.dart';
import 'package:flutter_test/flutter_test.dart';

/// 「不能改」的三種狀態。
///
/// 分開的理由是**處置不一樣**：封存是「這段歷史結束了」，沒有房是「你要從
/// 掛著它的聊天室進去才能動手」。講成同一句話的人，會去找一個不存在的
/// 封存狀態；講成「沒有權限」的人，會去翻設定頁。
void main() {
  test('有房且未封存＝可以改', () {
    expect(boardEditability(archived: false, hasRoom: true),
        BoardEditability.editable);
  });

  test('沒有房＝唯讀，但原因是「沒從聊天室進來」', () {
    expect(boardEditability(archived: false, hasRoom: false),
        BoardEditability.noRoom);
  });

  test('封存優先於有沒有房', () {
    // 封存的板從哪裡進來都改不了。判成 noRoom 的話畫面會說
    // 「從聊天室進來就能寫」——那句話在封存的板上是假的
    expect(boardEditability(archived: true, hasRoom: true),
        BoardEditability.archived);
    expect(boardEditability(archived: true, hasRoom: false),
        BoardEditability.archived);
  });
}
