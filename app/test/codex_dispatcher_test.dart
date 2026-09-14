import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:chatroom_app/models/agent_session.dart';
import 'package:chatroom_app/models/assignment.dart';
import 'package:chatroom_app/models/attachment.dart';
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

  /// 本機**活著**的 Codex thread（writer lock 存在＝進程還在）。
  /// 與忙碌無關——lock 是 session 全程都在的，2026-09-14 實測確認。
  late Set<String> liveThreads;

  /// 正在處理一個 turn 的 thread。這是**另一個訊號**，lock 答不了。
  /// `make` 預設讓兩個都忙著；投遞發生在它們空下來的時候，見 [settle]。
  late Set<String> busyThreads;

  CodexDispatcher make({
    RoomMembers members = defaultMembers,
    List<AgentSession>? sessions,
    Map<String, List<Assignment>> assignments = const {},
    Set<String>? activeThreads,
    Set<String>? live,
  }) {
    liveThreads = live ?? {threadA, threadB};
    busyThreads = activeThreads ?? {threadA, threadB};
    final d = CodexDispatcher(
      (_) async => members,
      fetchSessions: () async =>
          sessions ??
          [session(threadA, 'Codex-Sol'), session(threadB, 'Codex-Luna')],
      fetchAssignments: (thread) async => assignments[thread] ?? const [],
      activeThreadResolver: () => liveThreads,
      busyThreadResolver: () => busyThreads,
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

  /// Codex 的 turn 結束（**不是** lock 消失——那是進程結束），
  /// 下一輪輪詢把累積的批次投出去。
  /// 忙碌期間累積、空下來才投，所以「投給誰、內容對不對」的斷言都要先
  /// 經過這一步——那不是這些測試的主題，只是它們的前置。
  Future<void> settle(CodexDispatcher d) async {
    busyThreads.clear();
    await d.pollAssignments();
  }

  String target(List<String> argv) => argv[argv.indexOf('--thread') + 1];
  Map payload(List<String> argv) {
    final text = argv[argv.indexOf('--message') + 1];
    return jsonDecode(text.substring('[chatroom 通知] '.length)) as Map;
  }

  test('依房內 Codex 名稱把訊息送到精確 thread', () async {
    final d = make();
    await d.handle(batch([msg(1, content: '只給 Sol')]));
    await settle(d);
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
    await settle(d);
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
    await settle(d);
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
    // 本機只有 threadA 活著；訊息 @ 的 Codex-Luna 對應 threadB
    final d = make(live: const {threadA}, activeThreads: const {});
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

  test('狀態快照把「現在卡著什麼」講出來（設定頁顯示用）', () async {
    // 這條管線的失敗形狀全是靜默的：投不出去就留在記憶體等補投，畫面上
    // 一切正常。能回答「現在到底有沒有東西卡著」的欄位如果只有測試看得到，
    // 追查就只能靠推理。
    final d = make();
    await d.handle(batch([msg(1, content: '@Codex-Sol 在嗎')]));
    expect(d.status.value.pending, 1);
    expect(d.status.value.busyThreads, 2, reason: '兩個 thread 都在處理 turn');
    expect(d.status.value.localThreads, 2);
    expect(d.status.value.lastEvent, contains('待補投'));

    await settle(d);
    expect(d.status.value.pending, 0);
    expect(d.status.value.busyThreads, 0);
    expect(d.status.value.localThreads, 2, reason: '閒下來不等於不在了');
    expect(d.status.value.lastEvent, contains('已投遞'));
  });

  test('閒著的本機 Codex 也要報到、也收得到指派', () async {
    // writer lock 只在 Codex 持有寫入鎖時存在，所以 `activeThreadIds()`
    // 列出的是**正在處理 turn 的那些**。拿它當輪詢名單，等於「只有忙著的
    // agent 才報到、才撈得到指派」——指派一個閒著的 Codex，要等它自己
    // 動起來才收得到，而在那之前指派 UI 上它顯示成 idle。
    //
    // mention 那側早就改用「曾經見過 lock 的本機名冊」了（_roomRoutes），
    // 這裡是同一個道理的鏡像。
    final calls = <String>[];
    var assignmentReady = false;
    final d = CodexDispatcher(
      (_) async => defaultMembers,
      fetchSessions: () async => [session(threadA, 'Codex-Sol')],
      fetchAssignments: (thread) async {
        calls.add(thread);
        return assignmentReady ? [assignment('a1', threadA)] : const [];
      },
      activeThreadResolver: () => const {threadA},
      runProcess: (argv) async {
        runs.add(argv);
        return true;
      },
      codexArgvResolver: () => ['codex-bin'],
      codexHome: codexHome.path,
    )..enabled = true;

    await d.pollAssignments();
    expect(calls, [threadA]);
    calls.clear();

    // 這個 Codex 閒著（沒在跑 turn），指派在這段期間送進來
    assignmentReady = true;
    await d.pollAssignments();
    expect(calls, [threadA], reason: '閒著不等於不在——報到不能停');
    expect(runs, hasLength(1), reason: '閒著才是最該投得出去的時候');
    expect(target(runs.single), threadA);
    expect(payload(runs.single)['assignment_id'], 'a1');
  });

  group('board 變動', () {
    // board 與加入事件同一類：**狀態轉變，不是待辦**。通知只說「板子動了」，
    // 內容由收到的人自己去 chatroom_board 讀——所以合併是無損的，
    // 中間每一次變動都送過去，對方讀到的還是同一塊板。

    test('投給房內所有本機 Codex thread，內容只說板子動了', () async {
      final d = make();
      await d.handleBoardChange('r1', 7);
      expect(runs, hasLength(2), reason: 'threadA 與 threadB 都在 r1');
      expect(
        runs.map(target).toSet(),
        {threadA, threadB},
      );
      final p = payload(runs.first);
      expect(p['event'], 'board_changed');
      expect(p['board_seq'], 7);
      expect(p['action'], contains('chatroom_board'));
    });

    test('🔴 同一個週期內連續變動只喚醒一次，結束時補一則最新水位', () async {
      final d = make();
      await d.handleBoardChange('r1', 1);
      expect(runs, hasLength(2), reason: '第一則立刻送');
      runs.clear();

      // 拖板子：一口氣好幾個 board_seq
      await d.handleBoardChange('r1', 2);
      await d.handleBoardChange('r1', 3);
      await d.handleBoardChange('r1', 4);
      expect(runs, isEmpty, reason: '節流期間不逐則投');

      await d.pollAssignments();
      expect(runs, hasLength(2), reason: '週期結束補一則給兩個 thread');
      expect(payload(runs.first)['board_seq'], 4, reason: '只有最新的水位有意義');
    });

    test('下一個週期重新開放——節流不是永久靜音', () async {
      final d = make();
      await d.handleBoardChange('r1', 1);
      runs.clear();
      await d.pollAssignments(); // 週期結束，沒有待合併的
      expect(runs, isEmpty);

      await d.handleBoardChange('r1', 2);
      expect(runs, hasLength(2), reason: '新的週期第一則照樣立刻送');
    });

    test('🔴 房裡沒有本機 Codex 時不投，而且**不重試**', () async {
      // 「沒有人可以投」是確定性的結果，不是傳輸失敗。混在一起的代價是
      // 安靜的房每 10 秒重評估一次、log 每 10 秒刷一行，永遠不會停
      // （402cac6 的迴歸，Codex 09/14 實機抓到）。
      //
      // ⚠️ 斷言要看**重試的痕跡**而不是 runs：沒有 route 的時候重試一百次
      // 也不會產生任何 queue 呼叫，拿 runs 當斷言等於什麼都沒測。
      // 本機**有** Codex，只是它不在這個房——這樣 _roomRoutes 才真的會去
      // 查一次（本機一個都沒有時它提前返回，連查都不查，拿它當探針測不到）
      var lookups = 0;
      final d = CodexDispatcher(
        (_) async => defaultMembers,
        fetchSessions: () async {
          lookups++;
          return [
            AgentSession(
              sessionKey: threadA,
              kind: 'codex',
              label: 'Codex-別的房',
              status: 'active',
              lastSeenAt: '',
              rooms: const [
                SessionRoom(
                    roomId: 'other', roomName: '別的房', displayName: 'Codex-Sol'),
              ],
            ),
          ];
        },
        activeThreadResolver: () => {threadA},
        runProcess: (argv) async {
          runs.add(argv);
          return true;
        },
        codexArgvResolver: () => ['codex-bin'],
        codexHome: codexHome.path,
      )..enabled = true;

      await d.handleBoardChange('r1', 1);
      expect(runs, isEmpty);
      final after = lookups;

      await d.pollAssignments();
      await d.pollAssignments();
      expect(lookups, after, reason: '不重試——再查一百次也一樣沒有人可以投');
      expect(runs, isEmpty);
    });

    test('關閉轉送時不投', () async {
      final d = make()..enabled = false;
      await d.handleBoardChange('r1', 1);
      expect(runs, isEmpty);
    });

    test('🔴 還沒收過任何訊息就先收到 board 變動——房名照樣講得出來', () async {
      // 房名原本只從訊息批次記，於是安靜的房間在 App 重啟後的第一個 board
      // 事件會送出空字串（2026-09-14 實機 board_seq=7 正是如此，Codex 審出）。
      // 房間列表那側本來就知道房名，跟房的當下餵進來就好。
      final d = make();
      d.rememberRoomNames({'r1': '設計討論'});
      await d.handleBoardChange('r1', 3);
      expect(payload(runs.first)['room_name'], '設計討論');
    });

    test('🔴 同一個水位不重複喚醒，也不往回送更舊的', () async {
      // 同一次變動進來兩次的話：第一次立刻送、第二次進合併佇列，週期結束
      // 又送一遍同樣的 seq。收到的人已經讀到更新的水位，卻被叫醒去看一個
      // 比手上還舊的數字（實機：Codex 已讀到 10，連收兩次 9）。
      final d = make();
      await d.handleBoardChange('r1', 9);
      expect(runs, hasLength(2));
      runs.clear();

      await d.handleBoardChange('r1', 9); // 同一次變動又進來一次
      await d.pollAssignments();
      expect(runs, isEmpty, reason: '同水位不再送第二遍');

      await d.handleBoardChange('r1', 8); // 更舊的也不送
      expect(runs, isEmpty);

      await d.handleBoardChange('r1', 10); // 真的更新了才送
      expect(runs, hasLength(2));
      expect(payload(runs.first)['board_seq'], 10);
    });

    test('🔴 並行進來的同一個事件只喚醒一次', () async {
      // boardChanged.listen 的 callback 是 unawaited 的，兩個事件會並行。
      // 守門若落在 await 的另一側，兩邊都會通過而各送一次（Codex 審出）。
      final d = make();
      await Future.wait([
        d.handleBoardChange('r1', 9),
        d.handleBoardChange('r1', 9),
      ]);
      expect(runs, hasLength(2), reason: '兩個 thread 各一則，不是四則');
    });

    test('🔴 投遞還沒完成時進來的新水位不另外送，也不會把水位寫回去', () async {
      // 原本的形狀：seq=9 還在 await 時 seq=10 進來，兩邊都通過守門；
      // 若 10 先完成、9 後完成，9 會把 _lastBoardSent 從 10 寫回 9。
      final gate = Completer<void>();
      final d = CodexDispatcher(
        (_) async => defaultMembers,
        fetchSessions: () async =>
            [session(threadA, 'Codex-Sol'), session(threadB, 'Codex-Luna')],
        activeThreadResolver: () => {threadA, threadB},
        runProcess: (argv) async {
          runs.add(argv);
          if (payload(argv)['board_seq'] == 9) await gate.future;
          return true;
        },
        codexArgvResolver: () => ['codex-bin'],
        codexHome: codexHome.path,
      )..enabled = true;

      final first = d.handleBoardChange('r1', 9); // 卡在投遞裡
      await Future<void>.delayed(Duration.zero);
      await d.handleBoardChange('r1', 10); // 投遞進行中又來一個更新的
      expect(runs.where((r) => payload(r)['board_seq'] == 10), isEmpty,
          reason: '還在送上一則，這則要留到週期結束');

      gate.complete();
      await first;
      await d.pollAssignments();

      final seqs = runs.map((r) => payload(r)['board_seq']).toList();
      expect(seqs.where((x) => x == 9), hasLength(2), reason: '9 只送一輪');
      expect(seqs.where((x) => x == 10), hasLength(2), reason: '10 由週期結束補送');
      expect(seqs.last, 10, reason: '水位只能往前——9 不可以排在 10 後面');
    });

    test('🔴 一則都沒送成就不算送出，水位不可以往前', () async {
      // 原本不論 _queue 回什麼都回 true，於是「找不到 codex CLI」
      // 「exit 非零」「逾時」這些**正常的失敗契約**全被記成已投遞，
      // 水位照推，那一則變動從此沒有人會知道（Codex 審出）。
      var ok = false;
      final d = CodexDispatcher(
        (_) async => defaultMembers,
        fetchSessions: () async => [session(threadA, 'Codex-Sol')],
        activeThreadResolver: () => {threadA},
        runProcess: (argv) async {
          runs.add(argv);
          return ok;
        },
        codexArgvResolver: () => ['codex-bin'],
        codexHome: codexHome.path,
      )..enabled = true;

      await d.handleBoardChange('r1', 5);
      expect(runs, hasLength(1), reason: '嘗試過');
      runs.clear();

      ok = true;
      await d.pollAssignments();
      expect(runs, hasLength(1), reason: '沒送成就要重試，不能當作已送');
      expect(payload(runs.single)['board_seq'], 5);

      runs.clear();
      await d.pollAssignments();
      expect(runs, isEmpty, reason: '送成之後才不再重送');
    });

    test('🔴 投遞中與後續水位接連失敗，之後仍重試得回來', () async {
      // 「先佔位、失敗再還回去」的版本在這裡會壞：10 先失敗會先移掉 11 的
      // 名額，11 再失敗又把水位還原成 10——兩則都沒送成，卻記成 10 已送，
      // 之後同水位永遠被擋掉（Codex 審出）。
      final gate = Completer<void>();
      var fail = true;
      final d = CodexDispatcher(
        (_) async => defaultMembers,
        fetchSessions: () async => [session(threadA, 'Codex-Sol')],
        activeThreadResolver: () => {threadA},
        runProcess: (argv) async {
          runs.add(argv);
          if (payload(argv)['board_seq'] == 10) await gate.future;
          return !fail;
        },
        codexArgvResolver: () => ['codex-bin'],
        codexHome: codexHome.path,
      )..enabled = true;

      final first = d.handleBoardChange('r1', 10);
      await Future<void>.delayed(Duration.zero);
      await d.handleBoardChange('r1', 11); // 投遞中，進合併佇列
      gate.complete();
      await first; // 10 失敗

      fail = false;
      runs.clear();
      await d.pollAssignments();
      expect(runs, hasLength(1), reason: '失敗的水位要留得住，重試得回來');
      expect(payload(runs.single)['board_seq'], 11, reason: '留最高的那個');

      runs.clear();
      await d.pollAssignments();
      expect(runs, isEmpty);
    });

    test('通知帶得出房名——只給 roomId 的話收到的人不知道是哪個房', () async {
      final d = make();
      await d.handle(batch([msg(1)])); // 房名從訊息批次順手記下來
      runs.clear();
      await d.handleBoardChange('r1', 5);
      expect(payload(runs.first)['room_name'], '設計討論');
    });
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
    final d = make(live: const {}, activeThreads: const {});
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
    // 加入事件不受投遞時機反轉影響（它不走 mention 分流，也不累積）；
    // mention 那一半要等它空下來。
    await settle(d);
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

  test('本機人類 @ 本機 Codex（全鏈）——與加入事件同一條 feed', () async {
    // 實測回報的形狀：加入通知與指派都收得到、mention 一則都收不到。
    // 前兩者不比對名字，只有 mention 走 routes[key]，所以這條測的是
    // 「key 這一半在真實接線下對不對得上」。
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
    feeds['r1']!.upsertAll([msg(1, mentions: const [])]);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    runs.clear();

    // 人類自己發的、@ 到房內某個本機 Codex
    feeds['r1']!.upsertAll([
      msg(2,
          senderId: 'p-human',
          sender: 'piyan',
          content: '@Codex-Sol 你看得到這張圖嗎',
          mentions: const ['Codex-Sol']),
    ]);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await settle(d);

    expect(runs, hasLength(1), reason: '被 @ 的那個 thread 該收到');
    expect(target(runs.single), threadA);
    expect(payload(runs.single)['event'], 'message');
    expect(payload(runs.single)['latest']['sender'], 'piyan');
    center.dispose();
  });

  test('lock 還沒出現時留著，Codex 一活過來就投（完整生命週期）', () async {
    // lock 回答的是「這個 Codex 進程在這台機器上活著嗎」——**只有這個**。
    // 它答不了「正在處理 turn 嗎」（2026-09-14 實測：lock 是進程啟動時建立、
    // 整個 session 都在）。所以有了 lock 就該投，不必再等它「空下來」。
    var threads = <String>{};
    final d = CodexDispatcher(
      (_) async => defaultMembers,
      fetchSessions: () async => [session(threadA, 'Codex-Sol')],
      activeThreadResolver: () => threads,
      runProcess: (argv) async {
        runs.add(argv);
        return true;
      },
      codexArgvResolver: () => ['codex-bin'],
      codexHome: codexHome.path,
    )..enabled = true;
    await d.handle(batch([msg(1, content: '@Codex-Sol 在嗎')]));
    expect(runs, isEmpty, reason: '沒有正面證據說它在這台機器上');
    expect(d.pendingCount, 1, reason: '但要留著');

    // Codex 進程起來了，lock 出現——這下知道它是本機的，而且沒有忙碌閘門
    threads = {threadA, threadB};
    await d.pollAssignments();
    expect(runs, hasLength(1), reason: '活著就投，不必等它「空下來」');
    expect(target(runs.single), threadA);
    expect(payload(runs.single)['latest']['content'], '@Codex-Sol 在嗎');
    expect(d.pendingCount, 0, reason: '送到了就不再留');
  });

  test('查得到本機 Codex 但沒 @ 到它——不重試，直接丟', () async {
    // 與上一條的分界：這是確定性的結果，留著只會佔位子到過期。
    final d = make();
    await d.handle(batch([msg(1, mentions: const ['Bernie'])]));
    expect(runs, isEmpty);
    expect(d.pendingCount, 0);
  });

  test('一則出錯不連累同批其他則，也不讓訂閱靜默', () async {
    // 打在真正沒有內層 catch 的地方：`_fetchMembers` / `_roomRoutes` 各自
    // 都接得住自己的失敗，投遞那一段沒有。
    var firstCall = true;
    final busy = <String>{threadA};
    final d = CodexDispatcher(
      (_) async => defaultMembers,
      fetchSessions: () async => [session(threadA, 'Codex-Sol')],
      activeThreadResolver: () => const {threadA},
      busyThreadResolver: () => busy,
      runProcess: (argv) async {
        if (firstCall) {
          firstCall = false;
          throw StateError('spawn codex 炸了');
        }
        runs.add(argv);
        return true;
      },
      codexArgvResolver: () => ['codex-bin'],
      codexHome: codexHome.path,
    )..enabled = true;

    // 忙碌期間先累積（順便讓它認得 threadA 是本機的）
    await d.handle(batch([msg(1, content: '@Codex-Sol 第一則')]));
    expect(runs, isEmpty);
    expect(d.pendingCount, 1);

    // 空下來要投了，spawn 在這一刻炸掉——不可以往外拋
    //（Stream 的 onData 拋錯會變成未處理錯誤）
    busy.clear();
    await d.pollAssignments();
    expect(runs, isEmpty);
    expect(d.pendingCount, 1, reason: '炸掉的那批也要留著補投');

    // 下一批照常運作，訂閱沒有因為前一批出錯而靜默
    await d.handle(batch([msg(2, content: '@Codex-Sol 第二則')]));
    expect(runs, isNotEmpty);
  });

  test('帶附件的 mention 照樣投得出去（附件只是 metadata）', () async {
    // 實測時懷疑過「那則帶 16MB 圖，是不是把管線毒死了」。附件在訊息上
    // 只有 metadata，轉送 payload 也不含它——這條把結論釘住。
    final d = make();
    final withFile = Message(
      id: 'm9',
      seq: 9,
      updateSeq: 0,
      kind: 'chat',
      content: '@Codex-Sol 你看得到這張圖嗎',
      createdAt: '',
      senderId: 'p-human',
      senderName: 'piyan',
      mentions: const ['Codex-Sol'],
      attachments: const [
        Attachment(
          id: 'a1',
          filename: '20241226_141155.png',
          mime: 'image/png',
          size: 16174321,
          isImage: true,
        ),
      ],
    );
    await d.handle(batch([withFile]));
    await settle(d);
    expect(runs, hasLength(1));
    expect(target(runs.single), threadA);
    expect(payload(runs.single)['latest']['content'], '@Codex-Sol 你看得到這張圖嗎');
  });

  test('threadOverride 下加入事件仍投得出去', () async {
    final d = make()..threadOverride = threadB;
    await d.handle(batch([joinMsg(1)]));
    expect(runs, hasLength(1));
    expect(target(runs.single), threadB);
    expect(payload(runs.single)['event'], 'member_joined');
  });

  test('threadOverride 下成員名冊查不到時，mention 仍投得出去', () async {
    // 這個組合正是實測到的症狀：加入通知會到、mention 一則都不到。
    // 空成員名冊讓 codexNames 變成空集合，而 mention 過濾拿它當比對基準，
    // 於是「查不到」被當成「房裡沒有 Codex」——安靜地整條通道斷掉。
    final d = make(members: const RoomMembers(resolved: false))
      ..threadOverride = threadB;
    await d.handle(batch([msg(1, content: '@Codex-Sol 在嗎')]));
    expect(runs, hasLength(1));
    expect(target(runs.single), threadB);
    expect(payload(runs.single)['event'], 'message');
  });

  test('成員名冊查得到但房裡沒有 Codex 時，override 不投遞', () async {
    // 與上一條的分界：查到了、確實沒有 Codex，那就該安靜。
    final d = make(members: const RoomMembers(kinds: {'p-claude': 'claude'}))
      ..threadOverride = threadB;
    await d.handle(batch([msg(1, content: '@Novia 在嗎', mentions: ['Novia'])]));
    expect(runs, isEmpty);
  });

  // ── 投遞時機反轉（卡 261519cd 第一階段）───────────────────────────
  //
  // writer lock 存在＝Codex 正在處理一個 turn。原本的判讀反了：把「查得到
  // lock」當成「投得出去」，結果恰好在它最忙的時候把每一則各排一次 queue，
  // 等當前 turn 結束後逐筆倒灌。CLI 沒有 replace/dedupe/cancel，入列就撤不回。
  //
  // 反轉之後：忙碌期間只累積不投，lock 消失（轉 idle）才投一次合併的批次。

  test('Codex 忙碌期間的連續 mention 不逐筆投遞', () async {
    final active = <String>{threadA};
    final d = make(activeThreads: active);
    await d.handle(batch([msg(1, content: '@Codex-Sol 一')]));
    await d.handle(batch([msg(2, content: '@Codex-Sol 二')]));
    await d.handle(batch([msg(3, content: '@Codex-Sol 三')]));
    expect(runs, isEmpty, reason: '它正在忙，這三則都不該現在入列');
    expect(d.pendingCount, 3, reason: '但一則都不能丟');
  });

  test('轉 idle 後只送一批，內容是期間累積的全部', () async {
    final active = <String>{threadA};
    final d = make(activeThreads: active);
    await d.handle(batch([msg(1, content: '@Codex-Sol 一')]));
    await d.handle(batch([msg(2, content: '@Codex-Sol 二')]));
    await d.handle(batch([msg(3, content: '@Codex-Sol 三')]));

    active.clear(); // lock 消失＝當前 turn 結束，Codex 閒著等輸入
    await d.pollAssignments();

    expect(runs, hasLength(1), reason: '三則合成一次喚醒，不是三次');
    expect(target(runs.single), threadA);
    final p = payload(runs.single);
    expect(p['count'], 3);
    expect(p['latest']['seq'], 3, reason: '帶最新的那則');
    expect(d.pendingCount, 0);
  });

  test('🔴 lock 消失就不再向 Hub 報到——結束的 session 不可以被續命', () async {
    // 曾經有一份「只增不減」的本機名冊疊在 lock 上面，理由是「Codex 閒著
    // 時 lock 會消失」。那個前提是錯的，而代價是：App 啟動以來見過的每個
    // thread 每 10 秒被報到一次，早就結束的 session 在指派 UI 上永遠 ACTIVE。
    // 實測本機 4 個 lock、候選名單卻列出 11 個。
    final checkedIn = <String>[];
    final live = <String>{threadA, threadB};
    final d = CodexDispatcher(
      (_) async => defaultMembers,
      fetchSessions: () async => const [],
      fetchAssignments: (thread) async {
        checkedIn.add(thread);
        return const [];
      },
      activeThreadResolver: () => live,
      runProcess: (argv) async {
        runs.add(argv);
        return true;
      },
      codexArgvResolver: () => ['codex-bin'],
      codexHome: codexHome.path,
    )..enabled = true;

    await d.pollAssignments();
    expect(checkedIn, [threadA, threadB]);

    // threadB 的 Codex 收掉了，lock 隨之消失
    checkedIn.clear();
    live.remove(threadB);
    await d.pollAssignments();
    expect(checkedIn, [threadA], reason: '死掉的那個不可以繼續報到');
  });

  test('沒有 lock 的 thread 不投——那台機器上沒有這個 Codex', () async {
    // 與上一條的分界：沒有正面證據說它在這台機器上活著，就不能投。
    final d = make(live: const {});
    await d.handle(batch([msg(1, content: '@Codex-Sol 在嗎')]));
    await d.pollAssignments();
    expect(runs, isEmpty);
    expect(d.pendingCount, 1, reason: '留著等它活過來');
  });

  /// 🔴 忙碌期間的加入事件逐筆入列（原卡 1e3ce054）。
  ///
  /// `codex queue` 的 exit 0 只代表接受入列，CLI 沒有 replace/dedupe/cancel——
  /// mention 那半因此改成「忙就累積、空下來合併投一次」，**加入事件沒有跟上**：
  /// 五個人陸續進房，Codex 的 turn 一結束就吃到五則。
  ///
  /// ⚠️ 但 join **不能照 mention 那樣累積後補投**：它是狀態轉變不是待辦。
  /// 累積十分鐘再倒出來的那份名單，中間有人進了又走，送到時已經是錯的。
  ///
  /// 所以做的是**節流**而不是佇列：忙碌期間第一則照送（agent 立刻知道
  /// 名錄變了，那正是這個通知的用途），同一個 turn 內後續的抑制掉。
  /// turn 結束就重置。這樣立刻性、不倒灌、不失真三件事同時成立。
  group('加入事件在忙碌期間節流', () {
    test('🔴 同一個 turn 內只喚醒一次，不逐筆倒灌', () async {
      final d = make(); // 兩個 thread 都忙
      await d.handle(batch([joinMsg(1, senderId: 'p-1', sender: '甲')]));
      await d.handle(batch([joinMsg(2, senderId: 'p-2', sender: '乙')]));
      await d.handle(batch([joinMsg(3, senderId: 'p-3', sender: '丙')]));

      // 每個 thread 各一則，不是各三則
      expect(runs.map(target).toList()..sort(), [threadA, threadB]..sort());
      for (final run in runs) {
        expect(payload(run)['event'], 'member_joined');
        expect(payload(run)['latest']['display_name'], '甲',
            reason: '送的是第一則，不是最後一則——後面那些是它引發的重查要處理的');
      }
    });

    test('turn 結束後重置：下一個 turn 的加入照樣喚醒得到', () async {
      final d = make();
      await d.handle(batch([joinMsg(1, senderId: 'p-1', sender: '甲')]));
      expect(runs, hasLength(2));
      runs.clear();

      // turn 結束（lock 消失）→ 再忙起來 → 又有人加入
      busyThreads.clear();
      await d.pollAssignments();
      busyThreads.addAll({threadA, threadB});
      await d.handle(batch([joinMsg(2, senderId: 'p-2', sender: '乙')]));

      expect(runs, hasLength(2), reason: '節流是 per-turn 的，不是永久靜音');
      expect(payload(runs.first)['latest']['display_name'], '乙');
    });

    test('沒在忙就不節流——連續加入各自送得出去', () async {
      // 對照組：節流的理由是「turn 進行中入列會倒灌」。沒有 turn 就沒有
      // 那個理由，這時壓掉通知只是讓 agent 少知道一件事
      final d = make();
      // 先讓兩個 thread 被看見過一次——`_knownLocalThreads` 是「這個 thread
      // 在本機嗎」的唯一來源，沒見過 lock 的 thread 本來就不投
      await d.handle(batch([joinMsg(0, senderId: 'p-0', sender: '零')]));
      busyThreads.clear();
      await d.pollAssignments();
      runs.clear();

      await d.handle(batch([joinMsg(1, senderId: 'p-1', sender: '甲')]));
      await d.handle(batch([joinMsg(2, senderId: 'p-2', sender: '乙')]));
      expect(runs, hasLength(4), reason: '兩則 × 兩個 thread');
    });
  });
}
