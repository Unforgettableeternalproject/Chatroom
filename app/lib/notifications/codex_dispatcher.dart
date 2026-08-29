import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';

import '../models/agent_session.dart';
import '../models/assignment.dart';
import '../models/message.dart';
import 'notification_center.dart';

final _log = Logger('codex_dispatch');

/// 房內成員快照：mention 過濾與防迴圈都靠它。
class RoomMembers {
  const RoomMembers({
    this.kinds = const {},
    this.codexNames = const {},
    this.allNames = const {},
    this.resolved = true,
  });

  /// 這份快照是不是真的查到了。
  ///
  /// 取不到成員時用空集合冒充「房裡沒有 Codex」，會讓 mention 轉送一則都
  /// 投不出去而畫面上什麼都不會說——加入通知不比對名字所以照投，於是症狀
  /// 長成「只有加入通知會到」。**查不到與查到零個必須分得開。**
  final bool resolved;

  /// participant_id（含 alias id）→ kind。
  final Map<String, String> kinds;

  /// active 的 Codex 成員 display_name（mention 過濾的比對集）。
  final Set<String> codexNames;

  /// 所有已知成員名（判斷快取是否過期：tag 到不認識的名字就重查）。
  final Set<String> allNames;
}

/// 把聊天室訊息經 `codex queue` 轉送進本機的 Codex session（外部喚醒）。
///
/// 這讓 app 同時是「人類看聊天室的視窗」與「本機 agent 的通知樞紐」——
/// 不需要另外掛 watcher 進程。桌面限定（手機上沒有 codex CLI）。
///
/// 只轉送 **有 @tag 到房內 Codex 成員** 的訊息——喚醒是打擾，必須值得；
/// 沒被 tag 的訊息 Codex 之後用 chatroom_read 自己撈（游標保證不漏）。
///
/// 每個本機 Codex writer lock 對應一個 thread id。Hub session 名錄提供
/// thread id ↔ 房間顯示名稱的映射，dispatcher 據此把不同通知送到不同 thread。
/// Codex A @tag Codex B 時只喚醒 B；若 A tag 自己則排除 A，避免通知迴圈。
class CodexDispatcher {
  CodexDispatcher(
    this._fetchMembers, {
    Future<List<AgentSession>> Function()? fetchSessions,
    Future<List<Assignment>> Function(String threadId)? fetchAssignments,
    Future<bool> Function(List<String> argv)? runProcess,
    List<String>? Function()? codexArgvResolver,
    this.activeThreadResolver,
    String? codexHome,
  }) : _runProcess = runProcess ?? _defaultRun,
       _codexArgvResolver = codexArgvResolver ?? _codexArgv,
       _fetchSessions = fetchSessions ?? (() async => const <AgentSession>[]),
       _fetchAssignments =
           fetchAssignments ?? ((_) async => const <Assignment>[]),
       _codexHome =
           codexHome ??
           '${Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'] ?? ''}'
               '${Platform.pathSeparator}.codex';

  /// roomId → 房內成員快照。
  final Future<RoomMembers> Function(String roomId) _fetchMembers;
  final Future<List<AgentSession>> Function() _fetchSessions;
  final Future<List<Assignment>> Function(String threadId) _fetchAssignments;
  final Future<bool> Function(List<String> argv) _runProcess;
  final List<String>? Function() _codexArgvResolver;
  final Set<String> Function()? activeThreadResolver;
  final String _codexHome;

  bool enabled = false;

  /// 診斷用覆寫：指定後所有 Codex 通知只送這個 thread。
  /// 留空時依房內 participant 精準分流到所有被 tag 的本機 Codex session。
  String threadOverride = '';

  final Map<String, RoomMembers> _memberCache = {};
  final Set<String> _seenAssignments = {};
  bool _pollingAssignments = false;

  /// 投不出去、等著補投的 mention。key 是 messageId（同一則只留一份）。
  ///
  /// mention 與指派的可靠度差距全在這裡：指派每 10 秒輪詢一次，自帶重試，
  /// 所以間歇性失敗看不出來；mention 只有事件抵達的那一瞬間一次機會，
  /// 而 `fresh` 不會重放。偏偏 Codex 閒著等輸入時 writer lock 掃不到，
  /// 人在打字講話的當下正是它最可能閒著的時候。
  final Map<String, _PendingMention> _pending = {};

  /// 補投佇列上限。塞爆時丟最舊的——留著十分鐘前的比留著兩小時前的有用。
  static const _pendingLimit = 50;

  /// 超過這個時間就不補投了。mention 是待辦不是狀態轉變，晚一點送到仍然
  /// 算數（十分鐘前 @ 你的人還在等），但久到對方已經自己去看了就沒意義。
  static const _pendingTtl = Duration(minutes: 30);

  @visibleForTesting
  int get pendingCount => _pending.length;

  Future<void> handle(RoomFreshBatch batch) async {
    // 一批裡任何一則出事都不該連累其他則，更不該讓整條訂閱從此靜默。
    // 這是無聲失效最好的溫床：轉送停了，畫面上一切正常。
    try {
      await _handle(batch);
    } catch (e, st) {
      _log.severe('轉送這一批時出錯（${batch.roomName}）：$e', e, st);
      _remember(batch, batch.messages.where((m) => m.mentions.isNotEmpty));
    }
  }

  Future<void> _handle(RoomFreshBatch batch) async {
    if (!enabled) return;
    // 「有人加入」走廣播，一般訊息走 mention 分流——兩條路徑的投遞對象
    // 算法完全不同：加入事件沒有 mentions，套 mention 分流會一個人都投不到。
    final joins = <Message>[];
    final chats = <Message>[];
    for (final m in batch.messages) {
      (m.isMemberJoined ? joins : chats).add(m);
    }
    final roomLabel =
        batch.roomName.isEmpty ? batch.roomId : batch.roomName;
    final members = await _members(batch.roomId, batch.messages);
    if (threadOverride.isNotEmpty) {
      // 成員名冊查不到時退回「有 @ 就投」：這個模式下轉送目標是人工指定的
      // 單一 thread，多投一則的代價遠低於整條 mention 通道無聲斷掉。
      if (!members.resolved) {
        _log.warning(
          '房間成員名冊查不到（$roomLabel），改以「訊息有 @ 任何人」放行 '
          'mention 轉送。防迴圈（不轉送 Codex 自己的發言）此時失效。',
        );
      }
      final msgs = chats
          .where(
            (m) =>
                members.kinds[m.senderId] != 'codex' &&
                (members.resolved
                    ? m.mentions.any(members.codexNames.contains)
                    : m.mentions.isNotEmpty),
          )
          .toList();
      if (msgs.isNotEmpty) {
        await _dispatchMessages(threadOverride, batch, msgs);
      }
      // 診斷覆寫模式下沒有 routes 可比對，加入事件一律投給指定 thread；
      // 排除自己加入由上游（NotificationCenter）以 sender_id 處理過了
      if (joins.isNotEmpty) {
        await _dispatchJoins(threadOverride, batch, joins);
      }
      return;
    }

    final routes = await _roomRoutes(batch.roomId);
    final byThread = <String, List<Message>>{};
    for (final m in chats) {
      final senderThreads = routes[m.senderName] ?? const <String>{};
      for (final mention in m.mentions) {
        for (final thread in routes[mention] ?? const <String>{}) {
          if (senderThreads.contains(thread)) continue; // 不喚醒訊息作者自己
          final msgs = byThread.putIfAbsent(thread, () => <Message>[]);
          if (!msgs.any((known) => known.id == m.id)) msgs.add(m);
        }
      }
    }
    // routes 空 = 這一刻查不到任何本機 Codex 在這個房。那是**暫時**的
    // （writer lock 只在 session 持有寫入鎖時存在，Codex 閒著等輸入時
    // 掃不到），不是「這個房沒有 Codex」——留著等下一輪補投。
    if (routes.isEmpty) {
      _remember(batch, chats.where((m) => m.mentions.isNotEmpty));
    } else {
      final tagged = {for (final m in chats) ...m.mentions};
      if (tagged.isNotEmpty && byThread.isEmpty) {
        // 查到了、但沒 @ 到它——這是確定性的結果，不重試。
        _log.info(
          'mention 未投遞（$roomLabel）：訊息 @ 了 ${tagged.join('、')}，'
          '本機 Codex 在這個房的名字是 ${routes.keys.join('、')}',
        );
      }
    }
    for (final entry in byThread.entries) {
      await _dispatchMessages(entry.key, batch, entry.value);
    }

    // routes 只含「本機 Codex session ∩ 已加入這個房」，正好就是該喚醒的
    // 全體。新成員自己不必被自己的加入事件叫醒。
    final joinsByThread = <String, List<Message>>{};
    final allThreads = routes.values.expand((t) => t).toSet();
    for (final m in joins) {
      final joinerThreads = routes[m.senderName] ?? const <String>{};
      for (final thread in allThreads) {
        if (joinerThreads.contains(thread)) continue;
        joinsByThread.putIfAbsent(thread, () => <Message>[]).add(m);
      }
    }
    for (final entry in joinsByThread.entries) {
      await _dispatchJoins(entry.key, batch, entry.value);
    }
  }

  Future<void> _dispatchMessages(
    String thread,
    RoomFreshBatch batch,
    List<Message> msgs,
  ) =>
      _dispatchMessagesOk(thread, batch, msgs);

  /// 回傳是否真的送達——補投要靠它決定該不該把訊息從佇列裡拿掉。
  Future<bool> _dispatchMessagesOk(
    String thread,
    RoomFreshBatch batch,
    List<Message> msgs,
  ) async {
    final last = msgs.last;
    final text =
        '[chatroom 通知] ${jsonEncode({
          'event': 'message',
          'room_id': batch.roomId,
          'room_name': batch.roomName,
          'target_session_id': thread,
          'count': msgs.length,
          'latest': {'seq': last.seq, 'sender': last.senderName, 'content': last.content, 'mentions': last.mentions},
        })}';
    final ok = await _queue(thread, text);
    if (!ok) _log.warning('codex queue 轉送失敗（thread=$thread）');
    return ok;
  }

  /// 有人加入房間——與訊息分開成獨立事件，agent 收到後可以決定要不要打招呼
  /// 或重查成員名錄（房內多了誰，mention 才挑得對名字）。
  Future<void> _dispatchJoins(
    String thread,
    RoomFreshBatch batch,
    List<Message> msgs,
  ) async {
    final last = msgs.last;
    final text =
        '[chatroom 通知] ${jsonEncode({
          'event': 'member_joined',
          'room_id': batch.roomId,
          'room_name': batch.roomName,
          'target_session_id': thread,
          'count': msgs.length,
          'latest': {'seq': last.seq, 'participant_id': last.senderId, 'display_name': last.senderName, 'content': last.content},
        })}';
    final ok = await _queue(thread, text);
    if (!ok) _log.warning('codex queue 轉送失敗（member_joined, thread=$thread）');
  }

  /// 記下投不出去的 mention，等下一輪補投。
  void _remember(RoomFreshBatch batch, Iterable<Message> msgs) {
    for (final m in msgs) {
      _pending[m.id] = _PendingMention(
        roomId: batch.roomId,
        roomName: batch.roomName,
        message: m,
        firstSeenTick: _tick,
      );
    }
    while (_pending.length > _pendingLimit) {
      final dropped = _pending.keys.first;
      _pending.remove(dropped);
      _log.warning('補投佇列已滿，丟棄最舊的一則 mention（$dropped）');
    }
  }

  /// 重試補投。跟著 [pollAssignments] 的 10 秒輪詢走——指派靠這個節奏顯得
  /// 可靠，mention 沒理由不共用它。
  Future<void> flushPendingMentions() async {
    if (!enabled || _pending.isEmpty) return;
    _tick++;
    // 過期的先清掉，並且**講出來**——安靜地丟掉待辦，跟沒有這個機制一樣
    final expiredTicks = _pendingTtl.inSeconds ~/ 10;
    final expired = _pending.entries
        .where((e) => _tick - e.value.firstSeenTick > expiredTicks)
        .map((e) => e.key)
        .toList();
    for (final id in expired) {
      final p = _pending.remove(id)!;
      _log.warning(
        'mention 補投逾時放棄（${p.roomName}）：'
        '${p.message.senderName} @ ${p.message.mentions.join('、')}'
        '——這則喚醒沒有送達任何本機 Codex',
      );
    }
    if (_pending.isEmpty) return;

    // 依房間分組重投：routes 是逐房查的
    final byRoom = <String, List<_PendingMention>>{};
    for (final p in _pending.values) {
      byRoom.putIfAbsent(p.roomId, () => []).add(p);
    }
    for (final entry in byRoom.entries) {
      final routes = await _roomRoutes(entry.key);
      if (routes.isEmpty) continue; // 還是查不到，下一輪再說
      final first = entry.value.first;
      final batch = RoomFreshBatch(
        roomId: entry.key,
        roomName: first.roomName,
        messages: [for (final p in entry.value) p.message],
      );
      final byThread = <String, List<Message>>{};
      for (final p in entry.value) {
        final m = p.message;
        final senderThreads = routes[m.senderName] ?? const <String>{};
        var routed = false;
        for (final mention in m.mentions) {
          for (final thread in routes[mention] ?? const <String>{}) {
            if (senderThreads.contains(thread)) continue;
            byThread.putIfAbsent(thread, () => <Message>[]).add(m);
            routed = true;
          }
        }
        // routes 查得到了，這則卻仍然投不到任何人——@ 的不是本機 Codex，
        // 這是確定性的結果，繼續留著只會佔位子到過期
        if (!routed) _pending.remove(m.id);
      }
      for (final t in byThread.entries) {
        if (await _dispatchMessagesOk(t.key, batch, t.value)) {
          for (final m in t.value) {
            _pending.remove(m.id);
          }
          _log.info('mention 補投成功（${first.roomName}，${t.value.length} 則）');
        }
      }
    }
  }

  /// 單調遞增的輪詢計數。不用時鐘——`Duration` 要靠 `DateTime.now()`，
  /// 而測試裡沒辦法讓它前進。輪詢節奏固定 10 秒，用次數換算就夠了。
  int _tick = 0;

  /// 掃描本機 Codex sessions、向 Hub 報到並投遞各自的 pending assignment。
  /// 即使轉送開關關閉仍會輪詢，讓指派 UI 能看見活躍 session；只有 queue 受
  /// [enabled] 控制。
  Future<void> pollAssignments() async {
    if (_pollingAssignments) return;
    _pollingAssignments = true;
    try {
      // 借同一個節奏補投 mention——投不出去的原因（Codex 沒在跑）與這裡
      // 要等的東西是同一件事
      try {
        await flushPendingMentions();
      } catch (e) {
        _log.warning('mention 補投失敗：$e');
      }
      for (final thread in activeThreadIds()) {
        try {
          final assignments = await _fetchAssignments(thread);
          if (!enabled) continue;
          for (final a in assignments) {
            if (_seenAssignments.contains(a.id)) continue;
            final text =
                '[chatroom 通知] ${jsonEncode({'event': 'assignment', 'assignment_id': a.id, 'room_id': a.roomId, 'room_name': a.roomName, 'room_topic': a.roomTopic, 'assigned_name': a.assignedName, 'note': a.note, 'target_session_id': thread, 'action': '請呼叫 chatroom_join(room_id, assignment_id=assignment_id) 接受並加入'})}';
            if (await _queue(thread, text)) {
              _seenAssignments.add(a.id);
            }
          }
        } catch (e) {
          _log.warning('Codex session 報到／指派輪詢失敗（thread=$thread）：$e');
        }
      }
    } finally {
      _pollingAssignments = false;
    }
  }

  Future<Map<String, Set<String>>> _roomRoutes(String roomId) async {
    try {
      final local = activeThreadIds();
      if (local.isEmpty) return const {};
      final sessions = await _fetchSessions();
      final routes = <String, Set<String>>{};
      for (final session in sessions) {
        if (session.kind != 'codex' || !local.contains(session.sessionKey)) {
          continue;
        }
        for (final room in session.rooms.where((r) => r.roomId == roomId)) {
          final threads = routes.putIfAbsent(
            room.displayName,
            () => <String>{},
          );
          threads.add(session.sessionKey);
        }
      }
      return routes;
    } catch (e) {
      _log.warning('取得 Codex session 路由失敗：$e');
      return const {};
    }
  }

  Future<RoomMembers> _members(String roomId, List<Message> messages) async {
    var cached = _memberCache[roomId];
    // 過期條件：未知 sender，或 tag 到不認識的名字（剛加入的成員）
    final stale =
        cached == null ||
        messages.any(
          (m) =>
              (m.senderId != null && !cached!.kinds.containsKey(m.senderId)) ||
              m.mentions.any((n) => !cached!.allNames.contains(n)),
        );
    if (stale) {
      try {
        cached = await _fetchMembers(roomId);
        _memberCache[roomId] = cached;
      } catch (e) {
        _log.warning('取得房間成員失敗（$roomId）：$e');
        cached ??= const RoomMembers(resolved: false);
      }
    }
    return cached;
  }

  /// writer lock 檔名就是 Codex thread UUID；一次回傳全部，供多 session 分流。
  Set<String> activeThreadIds() {
    if (threadOverride.isNotEmpty) return {threadOverride};
    final resolver = activeThreadResolver;
    if (resolver != null) return resolver();
    try {
      final dir = Directory(
        '$_codexHome${Platform.pathSeparator}thread-writer-locks',
      );
      if (!dir.existsSync()) return const {};
      final threads = <String>{};
      for (final f in dir.listSync().whereType<File>()) {
        if (!f.path.endsWith('.lock')) continue;
        final name = f.uri.pathSegments.last;
        final thread = name.substring(0, name.length - '.lock'.length);
        if (_threadIdPattern.hasMatch(thread)) threads.add(thread);
      }
      return threads;
    } catch (e) {
      _log.warning('掃描 Codex session 失敗：$e');
      return const {};
    }
  }

  static final _threadIdPattern = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
  );

  Future<bool> _queue(String thread, String text) async {
    final argv = _codexArgvResolver();
    if (argv == null) {
      _log.warning('找不到 codex CLI，略過轉送');
      return false;
    }
    return _runProcess([
      ...argv,
      'queue',
      '--thread',
      thread,
      '--message',
      text,
    ]);
  }

  /// 可直接 spawn 的 codex 呼叫方式（不經 shell——訊息內容是不可信輸入，
  /// 經 cmd.exe 轉義是命令注入面）。Windows 的 codex 是 npm shim（.cmd），
  /// 改抓同目錄的 node.exe + codex.js。
  static List<String>? _codexArgv() {
    final pathVar = Platform.environment['PATH'] ?? '';
    final sep = Platform.isWindows ? ';' : ':';
    for (final dir in pathVar.split(sep)) {
      if (dir.isEmpty) continue;
      if (Platform.isWindows) {
        final cmd = File('$dir\\codex.cmd');
        if (cmd.existsSync()) {
          final node = File('$dir\\node.exe');
          final js = File('$dir\\node_modules\\@openai\\codex\\bin\\codex.js');
          if (node.existsSync() && js.existsSync()) {
            return [node.path, js.path];
          }
        }
        final exe = File('$dir\\codex.exe');
        if (exe.existsSync()) return [exe.path];
      } else {
        final f = File('$dir/codex');
        if (f.existsSync()) return [f.path];
      }
    }
    return null;
  }

  static Future<bool> _defaultRun(List<String> argv) async {
    try {
      final result = await Process.run(
        argv.first,
        argv.sublist(1),
      ).timeout(const Duration(seconds: 30));
      if (result.exitCode != 0) {
        _log.warning('codex queue exit ${result.exitCode}：${result.stderr}');
      }
      return result.exitCode == 0;
    } catch (e) {
      _log.warning('codex queue 執行失敗：$e');
      return false;
    }
  }
}

/// 等著補投的一則 mention。
class _PendingMention {
  const _PendingMention({
    required this.roomId,
    required this.roomName,
    required this.message,
    required this.firstSeenTick,
  });

  final String roomId;
  final String roomName;
  final Message message;

  /// 第一次投失敗時的輪詢計數，用來判斷是否過期。
  final int firstSeenTick;
}
