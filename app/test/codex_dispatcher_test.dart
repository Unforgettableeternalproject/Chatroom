import 'dart:convert';
import 'dart:io';

import 'package:chatroom_app/models/agent_session.dart';
import 'package:chatroom_app/models/assignment.dart';
import 'package:chatroom_app/models/message.dart';
import 'package:chatroom_app/notifications/codex_dispatcher.dart';
import 'package:chatroom_app/notifications/notification_center.dart';
import 'package:chatroom_app/ws/room_feed.dart';
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

/// 「有人加入」的 system 訊息。sender 就是加入者本人（Hub 把 pid 掛在
/// sender_id 上），而且**沒有 mentions**——所以它套不進 mention 分流。
Message joinMsg(
  int seq, {
  String? senderId = 'p-new',
  String sender = '測試Novia',
}) => Message(
  id: 'm$seq',
  seq: seq,
  updateSeq: 0,
  kind: 'system',
  content: '$sender 加入了聊天室',
  createdAt: '',
  senderId: senderId,
  senderName: sender,
  mentions: const [],
  systemEvent: 'join',
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

  test('有人加入時廣播給房內所有本機 Codex thread', () async {
    // 加入事件沒有 mentions，套 mention 分流會一個人都投不到——所以它必須
    // 走獨立的廣播路徑。這是「用 App 當通知樞紐的 Codex」唯一的到達方式，
    // 只測 Python watcher 抓不到這條。
    final d = make();
    await d.handle(batch([joinMsg(1)]));
    expect(runs, hasLength(2));
    expect(runs.map(target).toSet(), {threadA, threadB});
    for (final run in runs) {
      final body = payload(run);
      expect(body['event'], 'member_joined');
      expect(body['latest']['display_name'], '測試Novia');
      expect(body['latest']['participant_id'], 'p-new');
    }
  });

  test('加入者是本機 Codex 時不喚醒它自己', () async {
    final d = make();
    await d.handle(batch([joinMsg(1, senderId: 'p-codex-a', sender: 'Codex-Sol')]));
    expect(runs, hasLength(1));
    expect(target(runs.single), threadB);
  });

  test('加入事件與一般訊息同批時各走各的路徑', () async {
    final d = make();
    await d.handle(batch([msg(1, content: '只給 Sol'), joinMsg(2)]));
    final byEvent = <String, List<String>>{};
    for (final run in runs) {
      byEvent
          .putIfAbsent(payload(run)['event'] as String, () => <String>[])
          .add(target(run));
    }
    expect(byEvent['message'], [threadA], reason: 'mention 分流不受影響');
    expect(byEvent['member_joined']!.toSet(), {threadA, threadB});
  });

  test('本機人類加入時，同一台機器上的 Codex 一定收得到（全鏈）', () async {
    // 這是 B4 真正要保證的情境，而且是 NotificationCenter 與 dispatcher
    // 串起來才成立的：人類在 App 裡按加入 → Hub 發 join system 訊息 →
    // feed → NotificationCenter → dispatcher → 本機 Codex。
    // 中間任何一層拿「這是本機自己」當理由把它濾掉，這條鏈就斷了。
    final d = make();
    final feeds = <String, RoomFeed>{};
    final center = NotificationCenter(
      (roomId, {participantId}) =>
          feeds.putIfAbsent(roomId, () => RoomFeed(roomId)),
      (_) {},
      (_, _) {},
    );
    center.fresh.listen(d.handle);
    center.follow('r1', roomName: '設計討論', myParticipantId: 'p-human');
    // 先立基準線（首批快照是歷史，不通知）
    feeds['r1']!.upsertAll([msg(1, mentions: const [])]);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    runs.clear();

    // 人類自己加入：sender 就是這台 App 的 participant
    feeds['r1']!.upsertAll([joinMsg(2, senderId: 'p-human', sender: 'Bernie')]);
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(runs, hasLength(2), reason: '房內兩個本機 Codex thread 都該被喚醒');
    expect(runs.map(target).toSet(), {threadA, threadB});
    expect(payload(runs.first)['event'], 'member_joined');
    expect(payload(runs.first)['latest']['display_name'], 'Bernie');
    center.dispose();
  });

  test('threadOverride 下加入事件仍投得出去', () async {
    final d = make()..threadOverride = threadB;
    await d.handle(batch([joinMsg(1)]));
    expect(runs, hasLength(1));
    expect(target(runs.single), threadB);
    expect(payload(runs.single)['event'], 'member_joined');
  });
}
