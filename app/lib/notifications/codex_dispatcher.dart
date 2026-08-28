import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';

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
/// 防迴圈：Codex 自己發的訊息不轉送（sender 的 kind=codex 就略過），
/// 否則 Codex 會被自己的發言反覆喚醒。成員對照從房間詳情取得，
/// 出現未知的 sender 或 mention 名字時查一次並快取（含 alias_ids，
/// 改名重進也對得上）。
class CodexDispatcher {
  CodexDispatcher(
    this._fetchMembers, {
    Future<bool> Function(List<String> argv)? runProcess,
    List<String>? Function()? codexArgvResolver,
    String? codexHome,
  })  : _runProcess = runProcess ?? _defaultRun,
        _codexArgvResolver = codexArgvResolver ?? _codexArgv,
        _codexHome = codexHome ??
            '${Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'] ?? ''}'
                '${Platform.pathSeparator}.codex';

  /// roomId → 房內成員快照。
  final Future<RoomMembers> Function(String roomId) _fetchMembers;
  final Future<bool> Function(List<String> argv) _runProcess;
  final List<String>? Function() _codexArgvResolver;
  final String _codexHome;

  bool enabled = false;

  /// 指定 thread id；留空 = 自動抓最新的活躍 Codex session。
  String threadOverride = '';

  final Map<String, RoomMembers> _memberCache = {};

  Future<void> handle(RoomFreshBatch batch) async {
    if (!enabled) return;
    final members = await _members(batch.roomId, batch.messages);
    final msgs = <Message>[];
    for (final m in batch.messages) {
      final kind = m.senderId == null ? null : members.kinds[m.senderId];
      if (kind == 'codex') continue; // 防迴圈：不拿 Codex 的話喚醒 Codex
      // 只轉送有 tag 到房內 Codex 的訊息；其餘 Codex 自己用 chatroom_read 撈
      if (!m.mentions.any(members.codexNames.contains)) continue;
      msgs.add(m);
    }
    if (msgs.isEmpty) return;

    final thread = threadOverride.isNotEmpty ? threadOverride : _newestThread();
    if (thread == null) {
      _log.info('找不到活躍的 Codex session，略過轉送');
      return;
    }
    final argv = _codexArgvResolver();
    if (argv == null) {
      _log.warning('找不到 codex CLI，略過轉送');
      return;
    }

    final last = msgs.last;
    final text = '[chatroom 通知] ${jsonEncode({
          'room_id': batch.roomId,
          'room_name': batch.roomName,
          'count': msgs.length,
          'latest': {
            'seq': last.seq,
            'sender': last.senderName,
            'content': last.content,
            'mentions': last.mentions,
          },
        })}';
    final ok = await _runProcess(
        [...argv, 'queue', '--thread', thread, '--message', text]);
    if (!ok) _log.warning('codex queue 轉送失敗（thread=$thread）');
  }

  Future<RoomMembers> _members(String roomId, List<Message> messages) async {
    var cached = _memberCache[roomId];
    // 過期條件：未知 sender，或 tag 到不認識的名字（剛加入的成員）
    final stale = cached == null ||
        messages.any((m) =>
            (m.senderId != null && !cached!.kinds.containsKey(m.senderId)) ||
            m.mentions.any((n) => !cached!.allNames.contains(n)));
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

  /// 最新的活躍 Codex session：thread-writer-locks 內最近修改的 .lock。
  String? _newestThread() {
    try {
      final dir = Directory('$_codexHome${Platform.pathSeparator}thread-writer-locks');
      if (!dir.existsSync()) return null;
      File? newest;
      DateTime newestAt = DateTime.fromMillisecondsSinceEpoch(0);
      for (final f in dir.listSync().whereType<File>()) {
        if (!f.path.endsWith('.lock')) continue;
        final at = f.statSync().modified;
        if (at.isAfter(newestAt)) {
          newestAt = at;
          newest = f;
        }
      }
      if (newest == null) return null;
      final name = newest.uri.pathSegments.last;
      return name.substring(0, name.length - '.lock'.length);
    } catch (e) {
      _log.warning('掃描 Codex session 失敗：$e');
      return null;
    }
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
          final js = File(
              '$dir\\node_modules\\@openai\\codex\\bin\\codex.js');
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
      final result = await Process.run(argv.first, argv.sublist(1))
          .timeout(const Duration(seconds: 30));
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
