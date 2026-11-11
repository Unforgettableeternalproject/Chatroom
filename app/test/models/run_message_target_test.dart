import 'package:chatroom_app/core/errors/api_exception.dart';
import 'package:chatroom_app/models/agent_run.dart';
import 'package:chatroom_app/models/message.dart';
import 'package:chatroom_app/models/run_message_target.dart';
import 'package:flutter_test/flutter_test.dart';

/// 回報卡 -> 聊天訊息的對應規則。
void main() {
  String at(int minute, [int second = 0]) =>
      DateTime.utc(2026, 11, 11, 1, minute, second).toIso8601String();

  Message chat(int seq, String name, String when, {bool deleted = false}) =>
      Message(
        id: 'm$seq',
        seq: seq,
        updateSeq: 0,
        kind: 'chat',
        content: '發言 $seq',
        createdAt: when,
        senderId: 'p-$name',
        senderName: name,
        deleted: deleted,
      );

  Message system(int seq, String event, String when) => Message(
        id: 'm$seq',
        seq: seq,
        updateSeq: 0,
        kind: 'system',
        content: '派工 x／y 完成。',
        createdAt: when,
        systemEvent: event,
      );

  AgentRun ticket({String? agentName = 'Amber-Badger'}) => AgentRun(
        id: 'run-1',
        roomId: 'r1',
        kind: 'ticket',
        project: 'chatroom',
        ref: 'JSAI-2490',
        agentName: agentName,
        status: 'done',
        claimedAt: at(0, 5),
        startedAt: at(0, 10),
        endedAt: at(10),
        updatedAt: at(10),
      );

  AgentRun push() => AgentRun(
        id: 'run-p',
        roomId: 'r1',
        kind: 'push',
        project: 'chatroom',
        ref: 'chatroom',
        status: 'done',
        endedAt: at(30),
        updatedAt: at(30),
      );

  test('agent 報告：跳到該 agent 在這一輪的最後一則發言', () {
    final msgs = [
      chat(1, 'Amber-Badger', at(1)),
      chat(2, 'Someone-Else', at(5)),
      chat(3, 'Amber-Badger', at(9)),
      system(4, 'run_done', at(10, 1)),
    ];
    expect(resolveRunMessageSeq(ticket(), msgs), 3);
  });

  test('agent 報告：同名但在時間窗外的舊輪次與已刪訊息不算', () {
    final msgs = [
      chat(1, 'Amber-Badger', at(0, 0)), // 領單之前 15 秒以上
      chat(2, 'Amber-Badger', at(5)),
      chat(3, 'Amber-Badger', at(9), deleted: true),
      chat(4, 'Amber-Badger', at(20)), // 結束之後
    ];
    expect(resolveRunMessageSeq(ticket(), msgs), 2);
  });

  test('agent 報告：agent 沒發過言就不跳（不退回 system 訊息）', () {
    final msgs = [
      chat(1, 'Someone-Else', at(5)),
      system(2, 'run_done', at(10, 1)),
    ];
    expect(resolveRunMessageSeq(ticket(), msgs), isNull);
  });

  test('push 報告：用 system_event 加結束時間挑 run_done，不看內文', () {
    final msgs = [
      system(1, 'run_done', at(5)), // 別的派工的完成通知
      system(2, 'run_failed', at(30)), // 狀態不同
      chat(3, 'Amber-Badger', at(30)),
      system(4, 'run_done', at(30, 2)),
    ];
    expect(resolveRunMessageSeq(push(), msgs), 4);
  });

  test('push 報告：離結束時間太遠的 run_done 不算對應', () {
    final msgs = [system(1, 'run_done', at(5)), system(2, 'run_done', at(50))];
    expect(resolveRunMessageSeq(push(), msgs), isNull);
  });

  test('找不到任何對應訊息回 null', () {
    expect(resolveRunMessageSeq(ticket(), const []), isNull);
    expect(resolveRunMessageSeq(push(), const []), isNull);
  });

  group('run_id', () {
    Message withRun(Message m, String? runId) => Message(
          id: m.id,
          seq: m.seq,
          updateSeq: m.updateSeq,
          kind: m.kind,
          content: m.content,
          createdAt: m.createdAt,
          senderName: m.senderName,
          systemEvent: m.systemEvent,
          runId: runId,
        );

    test('Message.fromJson 解析 run_id；缺或空字串為 null', () {
      Map<String, dynamic> j(Object? v) => {
            'id': 'm',
            'seq': 1,
            'run_id': ?v,
          };
      expect(Message.fromJson(j('run-1')).runId, 'run-1');
      expect(Message.fromJson(j(null)).runId, isNull);
      expect(Message.fromJson(j('')).runId, isNull);
    });

    test('精確對應：同名但時間窗外的發言也以 run_id 為準，agent 取最後一則', () {
      final msgs = [
        withRun(chat(1, 'Amber-Badger', at(50)), 'run-1'),
        withRun(chat(2, 'Amber-Badger', at(55)), 'run-1'),
        withRun(chat(3, 'Amber-Badger', at(59)), 'run-other'),
        withRun(system(4, 'run_done', at(56)), 'run-1'),
      ];
      expect(runIdMessageSeq(ticket(), msgs), 2);
      expect(resolveRunMessageSeq(ticket(), msgs), 2);
    });

    test('沒有 agent 發言就取該 run 的 system 訊息', () {
      final msgs = [withRun(system(4, 'run_done', at(56)), 'run-1')];
      expect(runIdMessageSeq(ticket(), msgs), 4);
    });

    test('feed 內命中就不呼叫 API', () async {
      var called = false;
      final seq = await resolveRunMessageSeqRemote(
        ticket(),
        [withRun(chat(7, 'Amber-Badger', at(5)), 'run-1')],
        fetchLastSeq: (_) async {
          called = true;
          return 99;
        },
      );
      expect(seq, 7);
      expect(called, isFalse);
    });

    test('feed 外：走 API 取得 seq', () async {
      String? asked;
      final seq = await resolveRunMessageSeqRemote(
        ticket(),
        const [],
        fetchLastSeq: (id) async {
          asked = id;
          return 1234;
        },
      );
      expect(asked, 'run-1');
      expect(seq, 1234);
    });

    test('API 404：退回舊的時間窗比對', () async {
      final seq = await resolveRunMessageSeqRemote(
        ticket(),
        [chat(3, 'Amber-Badger', at(9))],
        fetchLastSeq: (_) async => throw const NotFoundException('run_message_not_found'),
      );
      expect(seq, 3);
    });

    test('API 與時間窗都對不上：安靜回 null，不丟例外', () async {
      final seq = await resolveRunMessageSeqRemote(
        ticket(),
        const [],
        fetchLastSeq: (_) async => throw const NetworkException(),
      );
      expect(seq, isNull);
    });
  });
}
