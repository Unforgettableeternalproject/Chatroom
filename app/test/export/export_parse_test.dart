import 'package:chatroom_app/api/export_api.dart';
import 'package:flutter_test/flutter_test.dart';

String _line(int seq, String content) =>
    '{"id":"m$seq","seq":$seq,"kind":"chat","content":"$content",'
    '"sender_name":"諾薇亞","created_at":"2026-08-31T09:00:00+00:00"}';

void main() {
  group('匯出 jsonl 的解析——匯出的價值在完整', () {
    test('一行一則，順序照原樣', () {
      final msgs = parseJsonl('${_line(1, "甲")}\n${_line(2, "乙")}\n');
      expect(msgs.map((m) => m.seq), [1, 2]);
      expect(msgs.first.content, '甲');
    });

    test('結尾與中間的空行跳過——那是正常的檔案結構，不是錯誤', () {
      final msgs = parseJsonl('${_line(1, "甲")}\n\n${_line(2, "乙")}\n\n');
      expect(msgs, hasLength(2));
    });

    test('完全空的 body 給空清單，不是例外——空房間匯出是合法的', () {
      expect(parseJsonl(''), isEmpty);
      expect(parseJsonl('\n\n'), isEmpty);
    });

    test('壞掉的一行讓整份失敗，不安靜跳過——'
        '少幾則的備份看起來完全正常，那比明確失敗糟得多', () {
      expect(() => parseJsonl('${_line(1, "甲")}\n{壞掉的\n${_line(2, "乙")}'),
          throwsA(isA<FormatException>()));
    });
  });
}
