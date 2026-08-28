import 'dart:convert';
import 'dart:io';

import 'package:chatroom_app/models/agent_session.dart';
import 'package:chatroom_app/models/assignment.dart';
import 'package:chatroom_app/models/message.dart';
import 'package:chatroom_app/notifications/codex_dispatcher.dart';
import 'package:chatroom_app/notifications/notification_center.dart';
import 'package:flutter_test/flutter_test.dart';

const threadA = '019d0000-0000-7000-8000-000000000001';
const threadB = '019d0000-0000-7000-8000-000000000002';

Message msg(
  int seq, {
  String? senderId = 'p-claude',
  String sender = 'Novia',
  String content = 'hi',
  List<String> mentions = const ['Codex-Sol'],
}) => Message(
  id: 'm$seq',
  seq: seq,
  updateSeq: 0,
  kind: 'chat',
  content: content,
  createdAt: '',
  senderId: senderId,
  senderName: sender,
  mentions: mentions,
);

const defaultMembers = RoomMembers(
  kinds: {'p-claude': 'claude', 'p-codex-a': 'codex', 'p-codex-b': 'codex'},
  codexNames: {'Codex-Sol', 'Codex-Luna'},
  allNames: {'Novia', 'Codex-Sol', 'Codex-Luna', 'Bernie'},
);

AgentSession session(String thread, String name) => AgentSession(
  sessionKey: thread,
  kind: 'codex',
  label: 'Codex-${thread.substring(thread.length - 8)}',
  status: 'active',
  lastSeenAt: '',
  rooms: [SessionRoom(roomId: 'r1', roomName: '設計討論', displayName: name)],
);

Assignment assignment(String id, String thread) => Assignment(
  id: id,
  roomId: 'r1',
  targetSessionKey: thread,
  note: '請檢查 dispatcher',
  assignedName: 'Sol',
  status: 'pending',
  createdAt: '',
  roomName: '設計討論',
  roomTopic: '多 session',
);

void main() {
  late List<List<String>> runs;
  late Directory codexHome;

  CodexDispatcher make({
    RoomMembers members = defaultMembers,
    List<AgentSession>? sessions,
    Map<String, List<Assignment>> assignments = const {},
    Set<String> activeThreads = const {threadA, threadB},
  }) {
    final d = CodexDispatcher(
      (_) async => members,
      fetchSessions: () async =>
          sessions ??
          [session(threadA, 'Codex-Sol'), session(threadB, 'Codex-Luna')],
      fetchAssignments: (thread) async => assignments[thread] ?? const [],
      activeThreadResolver: () => activeThreads,
      runProcess: (argv) async {
        runs.add(argv);
        return true;
      },
      codexArgvResolver: () => ['codex-bin'],
      codexHome: codexHome.path,
    );
    d.enabled = true;
    return d;
  }

  setUp(() {
    runs = [];
    codexHome = Directory.systemTemp.createTempSync('codex-home-');
  });

  tearDown(() => codexHome.deleteSync(recursive: true));

  RoomFreshBatch batch(List<Message> msgs) =>
      RoomFreshBatch(roomId: 'r1', roomName: '設計討論', messages: msgs);

  String target(List<String> argv) => argv[argv.indexOf('--thread') + 1];
  Map payload(List<String> argv) {
    final text = argv[argv.indexOf('--message') + 1];
    return jsonDecode(text.substring('[chatroom 通知] '.length)) as Map;
  }

  test('依房內 Codex 名稱把訊息送到精確 thread', () async {
    final d = make();
    await d.handle(batch([msg(1, content: '只給 Sol')]));
    expect(runs, hasLength(1));
    expect(target(runs.single), threadA);
    expect(payload(runs.single)['target_session_id'], threadA);
    expect(payload(runs.single)['latest']['content'], '只給 Sol');
  });

  test('同一批 mention 多個 Codex 時分別投遞', () async {
    final d = make();
    await d.handle(
      batch([
        msg(1, mentions: const ['Codex-Sol']),
        msg(2, mentions: const ['Codex-Sol', 'Codex-Luna']),
      ]),
    );
    expect(runs, hasLength(2));
    expect(runs.map(target).toSet(), {threadA, threadB});
    final byTarget = {for (final run in runs) target(run): payload(run)};
    expect(byTarget[threadA]!['count'], 2);
    expect(byTarget[threadB]!['count'], 1);
  });

  test('Codex A 可以喚醒 Codex B，但不會喚醒自己', () async {
    final d = make();
    await d.handle(
      batch([
        msg(
          1,
          senderId: 'p-codex-a',
          sender: 'Codex-Sol',
          mentions: const ['Codex-Sol', 'Codex-Luna'],
        ),
      ]),
    );
    expect(runs, hasLength(1));
    expect(target(runs.single), threadB);
  });

  test('沒有 tag 到可路由 Codex 的訊息不轉送', () async {
    final d = make();
    await d.handle(
      batch([
        msg(1, mentions: const []),
        msg(2, mentions: const ['Novia']),
      ]),
    );
    expect(runs, isEmpty);
  });

  test('Hub 中的遠端或非本機 thread 不由這台 App 投遞', () async {
    final d = make(activeThreads: const {threadA});
    await d.handle(
      batch([
        msg(1, mentions: const ['Codex-Luna']),
      ]),
    );
    expect(runs, isEmpty);
  });

  test('逐一輪詢活躍 thread 並只投遞一次 pending assignment', () async {
    final calls = <String>[];
    final d = CodexDispatcher(
      (_) async => defaultMembers,
      fetchSessions: () async => const [],
      fetchAssignments: (thread) async {
        calls.add(thread);
        return thread == threadA ? [assignment('a1', threadA)] : const [];
      },
      activeThreadResolver: () => const {threadA, threadB},
      runProcess: (argv) async {
        runs.add(argv);
        return true;
      },
      codexArgvResolver: () => ['codex-bin'],
      codexHome: codexHome.path,
    )..enabled = true;

    await d.pollAssignments();
    await d.pollAssignments();
    expect(calls, [threadA, threadB, threadA, threadB]);
    expect(runs, hasLength(1));
    expect(target(runs.single), threadA);
    expect(payload(runs.single)['assignment_id'], 'a1');
    expect(payload(runs.single)['action'], contains('assignment_id'));
  });

  test('關閉轉送仍輪詢報到，但不 queue 指派', () async {
    var polls = 0;
    final d = CodexDispatcher(
      (_) async => defaultMembers,
      fetchAssignments: (_) async {
        polls++;
        return [assignment('a1', threadA)];
      },
      activeThreadResolver: () => const {threadA},
      runProcess: (argv) async {
        runs.add(argv);
        return true;
      },
      codexArgvResolver: () => ['codex-bin'],
      codexHome: codexHome.path,
    )..enabled = false;
    await d.pollAssignments();
    expect(polls, 1);
    expect(runs, isEmpty);
  });

  test('threadOverride 保留為單一目標診斷退路', () async {
    final d = make()..threadOverride = threadB;
    await d.handle(batch([msg(1)]));
    expect(runs, hasLength(1));
    expect(target(runs.single), threadB);
  });

  test('掃描 writer lock 時回傳全部合法 Codex thread UUID', () {
    final locks = Directory('${codexHome.path}/thread-writer-locks')
      ..createSync(recursive: true);
    File('${locks.path}/$threadA.lock').writeAsStringSync('');
    File('${locks.path}/$threadB.lock').writeAsStringSync('');
    File('${locks.path}/not-a-thread.lock').writeAsStringSync('');
    File('${locks.path}/.coordination.lock').writeAsStringSync('');
    final d = CodexDispatcher(
      (_) async => defaultMembers,
      codexHome: codexHome.path,
      codexArgvResolver: () => ['codex-bin'],
    );
    expect(d.activeThreadIds(), {threadA, threadB});
  });

  test('找不到任何 Codex session 時安靜略過', () async {
    final d = make(activeThreads: const {});
    await d.handle(batch([msg(1)]));
    expect(runs, isEmpty);
  });
}
