import 'package:flutter_test/flutter_test.dart';
import 'package:chatroom_app/core/util/member_nesting.dart';
import 'package:chatroom_app/models/participant.dart';

Participant _p(String id, String name, {String? parent, bool sub = false}) =>
    Participant(
      id: id,
      kind: 'claude',
      displayName: name,
      role: 'agent',
      status: 'active',
      joinedAt: '',
      ephemeral: sub,
      parentId: parent,
    );

void main() {
  group('成員列的子代理巢狀', () {
    test('子代理排到自己父層的正下方', () {
      final out = nestSubagents([
        _p('a', 'Novia'),
        _p('b', '米絲媞'),
        _p('s1', '米勒', parent: 'a', sub: true),
      ]);

      expect(out.map((p) => p.displayName), ['Novia', '米勒', '米絲媞']);
    });

    test('一般成員之間的既有順序不被打亂', () {
      // 不做成 sort 就是為了這件事——joined_at 的順序是有意義的
      final out = nestSubagents([
        _p('a', '甲'),
        _p('b', '乙'),
        _p('c', '丙'),
        _p('s1', '子', parent: 'b', sub: true),
      ]);

      expect(out.map((p) => p.displayName), ['甲', '乙', '子', '丙']);
    });

    test('同一父層的多個子代理維持彼此的順序', () {
      final out = nestSubagents([
        _p('a', 'Novia'),
        _p('s1', '米勒', parent: 'a', sub: true),
        _p('s2', '戴爾', parent: 'a', sub: true),
      ]);

      expect(out.map((p) => p.displayName), ['Novia', '米勒', '戴爾']);
    });

    test('父層不在清單裡的孤兒補在最後，不可消失', () {
      // 級聯移除保證這在正常情況下不會發生，但看不見的成員比排錯位置的
      // 成員危險得多——排版不該有能力讓一個人消失
      final out = nestSubagents([
        _p('a', 'Novia'),
        _p('s9', '孤兒', parent: 'not-in-list', sub: true),
      ]);

      expect(out.map((p) => p.displayName), ['Novia', '孤兒']);
    });

    test('沒有任何子代理時原樣返回', () {
      final input = [_p('a', '甲'), _p('b', '乙')];
      expect(nestSubagents(input), same(input));
    });

    test('每個人只出現一次', () {
      final out = nestSubagents([
        _p('a', 'Novia'),
        _p('b', '米絲媞'),
        _p('s1', '米勒', parent: 'a', sub: true),
        _p('s2', '埃里爾', parent: 'b', sub: true),
        _p('s3', '孤兒', parent: 'gone', sub: true),
      ]);

      expect(out.length, 5);
      expect(out.map((p) => p.id).toSet().length, 5);
    });
  });
}
