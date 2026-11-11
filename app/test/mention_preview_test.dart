import 'package:chatroom_app/core/mention_groups.dart';
import 'package:chatroom_app/models/participant.dart';
import 'package:flutter_test/flutter_test.dart';

Participant _p(String name, String role, {bool ephemeral = false}) =>
    Participant(
      id: 'id-$name',
      kind: role == 'human' ? 'human' : 'claude',
      displayName: name,
      role: role,
      status: 'active',
      joinedAt: '2026-01-01T00:00:00Z',
      ephemeral: ephemeral,
    );

/// 「會 tag 到」預覽：群組換中文，並略掉已被群組涵蓋的個別成員。
void main() {
  final members = [
    _p('Bernie', 'human'),
    _p('Alice', 'human'),
    _p('Core 開發 (工具層)', 'agent'),
    _p('Novia', 'agent'),
    _p('Sub', 'agent', ephemeral: true),
  ];

  test('@agents 加個別 agent 只顯示「全部 agent」', () {
    expect(
      mentionPreviewNames(['Core 開發 (工具層)', 'agents', 'Novia'], members),
      ['全部 agent'],
    );
  });

  test('@humans 加個別人類與個別 agent 時，agent 仍要列', () {
    expect(
      mentionPreviewNames(
          ['humans', 'Bernie', 'Alice', 'Core 開發 (工具層)'], members),
      ['全部人類', 'Core 開發 (工具層)'],
    );
  });

  test('@all 只顯示「所有人」', () {
    expect(
      mentionPreviewNames(
          ['Bernie', 'all', 'agents', 'Novia', 'humans'], members),
      ['所有人'],
    );
  });

  test('無群組時照舊列名', () {
    expect(mentionPreviewNames(['Novia', 'Bernie'], members),
        ['Novia', 'Bernie']);
  });

  test('群組大小寫不敏感且不重複', () {
    expect(mentionPreviewNames(['Agents', 'agents'], members), ['全部 agent']);
  });

  test('群組不會展開到的人（發話者自己、subagent）仍要列', () {
    expect(
      mentionPreviewNames(['agents', 'Sub', 'Novia'], members,
          selfParticipantId: 'id-Novia'),
      ['全部 agent', 'Sub', 'Novia'],
    );
  });
}
