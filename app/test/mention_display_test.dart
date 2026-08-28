import 'package:chatroom_app/widgets/markdown_body.dart';
import 'package:flutter_test/flutter_test.dart';

/// mention 在這個系統裡是結構化欄位，與正文寫不寫 `@` 無關。人類在 App 用
/// mention_field 打字會把 `@名字` 帶進正文，agent 直接帶 mentions 參數則不會
/// ——後者過去在泡泡上完全看不出有 tag 人（2026-08-29 實機發現）。
void main() {
  group('unrenderedMentions', () {
    test('agent 只帶 mentions 參數、正文沒有 @ 時全部列出', () {
      expect(
        unrenderedMentions('通知測試，這則只 mention 你一個人。', ['Bernie']),
        ['Bernie'],
      );
    });

    test('正文已寫 @名字 的不重複列（內文本來就會渲染成 chip）', () {
      expect(unrenderedMentions('@Bernie 看一下', ['Bernie']), isEmpty);
    });

    test('混合情況只補沒寫的那些', () {
      expect(
        unrenderedMentions('@Bernie 幫我看，順便叫米勒', ['Bernie', '米勒']),
        ['米勒'],
      );
    });

    test('沒有 mentions 就沒有東西可補', () {
      expect(unrenderedMentions('@Bernie', const []), isEmpty);
    });

    test('名字含空白與連字號（指派帶入的名稱常長這樣）', () {
      expect(
        unrenderedMentions('對接完成', ['對接人員 - 諾薇亞一號']),
        ['對接人員 - 諾薇亞一號'],
      );
      expect(
        unrenderedMentions('@對接人員 - 諾薇亞一號 收到', ['對接人員 - 諾薇亞一號']),
        isEmpty,
      );
    });

    test('前綴名字不被較長的名字誤判為已渲染', () {
      // 正文只有 @Nova-2，Nova 仍該補上——否則被 ping 的人在泡泡上消失
      expect(unrenderedMentions('@Nova-2 看看', ['Nova', 'Nova-2']), ['Nova']);
    });
  });
}
