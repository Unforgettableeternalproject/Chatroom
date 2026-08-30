import 'package:flutter_test/flutter_test.dart';
import 'package:chatroom_app/models/participant.dart';

/// 訊息氣泡要標「↳ 某某的子代理」，靠的是 sender_id → 父層名字 的對照。
///
/// 這裡驗的是那張表的建法（與 chat_screen 內的建法一致）：**alias 也要收**。
/// 父層離開後重進會拿到新的 participant id，舊 id 被 Hub 收進 alias_ids，
/// 而歷史 subagent 的 parent_id 指的是舊的那個。
Map<String, String> buildNameById(List<Participant> members) => {
      for (final p in members) ...{
        p.id: p.displayName,
        for (final alias in p.aliasIds) alias: p.displayName,
      },
    };

Participant _p(
  String id,
  String name, {
  String? parent,
  bool sub = false,
  List<String> aliases = const [],
}) =>
    Participant(
      id: id,
      kind: 'claude',
      displayName: name,
      role: 'agent',
      status: 'active',
      joinedAt: '',
      ephemeral: sub,
      parentId: parent,
      aliasIds: aliases,
    );

void main() {
  group('子代理的父層對照', () {
    test('父層重進後，歷史子代理仍對得回父層名字', () {
      // 父層離開重進：新 id p2、舊 id p1 進了 aliasIds
      final members = [
        _p('p2', 'Novia', aliases: ['p1']),
        _p('s1', '米勒', parent: 'p1', sub: true),
      ];

      final nameById = buildNameById(members);
      expect(nameById['p1'], 'Novia', reason: '只收代表列會變成「（未知）的子代理」');
      expect(nameById['s1'], '米勒');
    });

    test('沒有 alias 時照常對得到', () {
      final members = [_p('p1', 'Novia'), _p('s1', '米勒', parent: 'p1', sub: true)];
      expect(buildNameById(members)['p1'], 'Novia');
    });
  });
}
