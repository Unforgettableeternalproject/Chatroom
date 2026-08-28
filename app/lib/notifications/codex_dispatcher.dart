import 'dart:convert';
import 'dart:io';

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
  });

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

  Future<void> handle(RoomFreshBatch batch) async {
    if (!enabled) return;
    final members = await _members(batch.roomId, batch.messages);
    if (threadOverride.isNotEmpty) {
      final msgs = batch.messages
          .where(
            (m) =>
                members.kinds[m.senderId] != 'codex' &&
                m.mentions.any(members.codexNames.contains),
          )
          .toList();
      if (msgs.isNotEmpty) {
        await _dispatchMessages(threadOverride, batch, msgs);
      }
      return;
    }

    final routes = await _roomRoutes(batch.roomId);
    final byThread = <String, List<Message>>{};
    for (final m in batch.messages) {
      final senderThreads = routes[m.senderName] ?? const <String>{};
      for (final mention in m.mentions) {
        for (final thread in routes[mention] ?? const <String>{}) {
          if (senderThreads.contains(thread)) continue; // 不喚醒訊息作者自己
          final msgs = byThread.putIfAbsent(thread, () => <Message>[]);
          if (!msgs.any((known) => known.id == m.id)) msgs.add(m);
        }
      }
    }
    for (final entry in byThread.entries) {
      await _dispatchMessages(entry.key, batch, entry.value);
    }
  }

  Future<void> _dispatchMessages(
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
  }

  /// 掃描本機 Codex sessions、向 Hub 報到並投遞各自的 pending assignment。
  /// 即使轉送開關關閉仍會輪詢，讓指派 UI 能看見活躍 session；只有 queue 受
  /// [enabled] 控制。
  Future<void> pollAssignments() async {
    if (_pollingAssignments) return;
    _pollingAssignments = true;
    try {
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
        cached ??= const RoomMembers();
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
