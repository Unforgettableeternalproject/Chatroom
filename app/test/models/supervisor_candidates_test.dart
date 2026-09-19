import 'package:chatroom_app/models/participant.dart';
import 'package:chatroom_app/screens/board/supervisor_panel.dart';
import 'package:flutter_test/flutter_test.dart';

/// 誰可以被指定為這間房的 supervisor（Supervisor 自派工 2026-09-19）。
///
/// Hub 那端已經以 409 `supervisor_cannot_be_run` 擋住派工跑起來的臨時成員，
/// 但**擋下來的那一刻人已經按下去了**：清單上留著一個一定會被退的名字，
/// 等於請人去撞一道牆，而且那個名字在 run 結束後就會從房裡消失。
Participant _p({
  required String id,
  String status = 'active',
  String runId = '',
}) =>
    Participant(
      id: id,
      kind: 'claude',
      displayName: id,
      role: 'agent',
      status: status,
      joinedAt: '2026-09-19T00:00:00+00:00',
      runId: runId,
    );

void main() {
  test('一般在房成員留著', () {
    final list = supervisorCandidates([_p(id: '米絲媞'), _p(id: '諾薇亞')]);
    expect(list.map((p) => p.id), ['米絲媞', '諾薇亞']);
  });

  test('🔴 派工跑起來的臨時成員不進清單', () {
    final list = supervisorCandidates([
      _p(id: '米絲媞'),
      _p(id: 'run-agent', runId: 'run-1'),
    ]);
    expect(list.map((p) => p.id), ['米絲媞']);
  });

  test('已離開的一樣不進清單', () {
    final list = supervisorCandidates([
      _p(id: '走了的', status: 'left'),
      _p(id: '米絲媞'),
    ]);
    expect(list.map((p) => p.id), ['米絲媞']);
  });
}
