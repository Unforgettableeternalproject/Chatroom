import 'package:chatroom_app/widgets/mention_field.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('extractMentions', () {
    const members = ['Nova', 'Nova-2', 'Ivory-Fox'];

    test('前綴重名：@Nova-2 不可誤 ping Nova（Codex blocker 2）', () {
      expect(extractMentions('@Nova-2 請看一下', members), ['Nova-2']);
    });

    test('短名本身仍可被提及', () {
      expect(extractMentions('@Nova 請看一下', members), ['Nova']);
    });

    test('同一訊息可同時提及長短名', () {
      final r = extractMentions('@Nova-2 和 @Nova 都來', members);
      expect(r.toSet(), {'Nova', 'Nova-2'});
    });

    test('右邊界：@Nova-25 不算提及 Nova-2 也不算 Nova', () {
      expect(extractMentions('@Nova-25 是誰', members), isEmpty);
    });

    test('名字在字串結尾', () {
      expect(extractMentions('交給 @Ivory-Fox', members), ['Ivory-Fox']);
    });

    test('緊接 CJK 文字仍算提及（自動完成不保證尾隨空白留存）', () {
      expect(extractMentions('@Nova請看', members), ['Nova']);
    });

    test('沒有 @ 就沒有提及', () {
      expect(extractMentions('Nova-2 只是被談論，不是被提及', members), isEmpty);
    });

    test('成員清單為空', () {
      expect(extractMentions('@Nova hi', const <String>[]), isEmpty);
    });
  });
}
