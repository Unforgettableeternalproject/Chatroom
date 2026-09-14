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

/// 轉送管線的當下狀態快照——**給人看的**。
///
/// 這條管線的失敗形狀全是靜默的：投不出去就留在記憶體等補投，畫面上
/// 一切正常。09/12 追「@ 了 Codex 卻沒醒」時，唯一能回答「現在到底有沒有
/// 東西卡著」的欄位是 `@visibleForTesting` 的——只有測試看得到，
/// 使用者與追查的人都看不到。
class CodexDispatchStatus {
  const CodexDispatchStatus({
    this.pending = 0,
    this.localThreads = 0,
    this.busyThreads = 0,
    this.lastEvent = '',
  });

  /// 投不出去、等著補投的 mention 則數。
  final int pending;

  /// 這台機器上認得的 Codex thread 數（不分忙閒）。
  final int localThreads;

  /// 其中正在處理 turn 的——投遞就是在等這個數字降下來。
  final int busyThreads;

  /// 最後一次有意義的投遞結果，一句中文。
  final String lastEvent;

  CodexDispatchStatus copyWith({
    int? pending,
    int? localThreads,
    int? busyThreads,
    String? lastEvent,
  }) => CodexDispatchStatus(
    pending: pending ?? this.pending,
    localThreads: localThreads ?? this.localThreads,
    busyThreads: busyThreads ?? this.busyThreads,
    lastEvent: lastEvent ?? this.lastEvent,
  );
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
    this.busyThreadResolver,
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

  /// 「哪些 thread 正在處理一個 turn」。**目前沒有任何可用訊號**——
  /// 見 [busyThreadIds]。給 null 時一律視為沒人在忙。
  final Set<String> Function()? busyThreadResolver;
  final String _codexHome;

  bool enabled = false;

  /// 診斷用覆寫：指定後所有 Codex 通知只送這個 thread。
  /// 留空時依房內 participant 精準分流到所有被 tag 的本機 Codex session。
  String threadOverride = '';

  final Map<String, RoomMembers> _memberCache = {};
  final Set<String> _seenAssignments = {};
  bool _pollingAssignments = false;

  /// 這個 turn 裡已經送過加入通知的 thread（節流用，見 [_dispatchJoins]）。
  final Set<String> _joinNoticedThisTurn = {};

  /// roomId → 房名。board 事件只帶 roomId，但通知裡要講得出是哪個房——
  /// 「某個房的板子動了」對收到的人沒有用。
  ///
  /// ⚠️ **不能只從訊息批次記**：安靜的房間一則訊息都沒有，App 重啟後
  /// 第一個 board 事件就會送出空的房名（2026-09-14 實機 board_seq=7
  /// 正是如此，Codex 審出）。所以房間列表那側也要餵一次。
  final Map<String, String> _roomNames = {};

  /// 從房間列表餵房名。跟著 `follow` 的節奏走，不必等房裡有人講話。
  void rememberRoomNames(Map<String, String> names) {
    for (final e in names.entries) {
      if (e.value.isNotEmpty) _roomNames[e.key] = e.value;
    }
  }

  /// 這個輪詢週期內已經為哪些房送過 board 通知（節流用）。
  final Set<String> _boardNoticedThisTick = {};

  /// 節流期間又動過的房：roomId → 最新的 board_seq。
  ///
  /// 只留最新的一個數字，不累積清單——board 是**狀態轉變不是待辦**，
  /// 收到的人要做的事是「去 chatroom_board 讀一次」，而那件事做一次就夠。
  /// 把中間每一次變動都送過去，對方讀到的還是同一塊板。
  final Map<String, int> _pendingBoards = {};

  /// 每個房已經喚醒到哪個水位。
  ///
  /// 沒有它會「同水位重複喚醒 + 水位倒退」：同一次變動若進來兩次，第一次
  /// 走立刻送、第二次被收進合併佇列，週期結束又送一遍同樣的 seq。收到的人
  /// 已經讀到更新的水位了，卻被叫醒去看一個比手上還舊的數字
  /// （2026-09-14 實機，Codex 已讀到 10 卻連收兩次 9）。
  ///
  /// 只前進：board_seq 是單調的，不比現在這個新就沒有東西要看。
  final Map<String, int> _lastBoardSent = {};

  /// 🔴 **哪些 thread 正在處理一個 turn——目前沒有任何可用訊號。**
  ///
  /// 2026-09-14 實測推翻了先前的前提：`~/.codex/thread-writer-locks/` 的
  /// lock 檔是 **Codex 進程啟動時建立、整個 session 期間都在**的，不是
  /// 每個 turn 開關一次。證據是 lock 的 CreationTime 與 codex 進程的
  /// StartTime 逐秒吻合，且數十分鐘內未再被修改。
  ///
  /// 把它當忙碌訊號的後果：每個活著的 Codex 都**永遠在忙**，mention 全數
  /// 沉進補投佇列、等不到「空下來」，30 分鐘後逾時丟棄。實測 @ 一個閒著的
  /// Codex 完全不會醒，而指派（不檢查忙碌）照常送達——「指派收得到、
  /// @ 收不到」就是這麼來的。
  ///
  /// 所以這裡誠實回傳空集合：**沒有訊號就不要假裝有**。找到真的能回答
  /// 「你在忙嗎」的介面時，插在這一個點就好，其餘邏輯都不必動。
  Set<String> busyThreadIds() => busyThreadResolver?.call() ?? const {};

  Set<String> _scanBusyThreads() {
    final busy = busyThreadIds();
    // 空下來就重置加入通知的節流：它是 per-turn 的，不是永久靜音
    _joinNoticedThisTurn.removeWhere((t) => !busy.contains(t));
    _publish();
    return busy;
  }

  /// 這台機器上活著的 Codex thread。
  ///
  /// lock 的壽命就是 session 的壽命，所以它**精準**回答這個問題——
  /// 一個進程結束、lock 消失，這裡就不再列它。
  ///
  /// ⚠️ 曾經有一份「只增不減」的本機名冊疊在這上面，理由是「Codex 閒著時
  /// lock 會消失」。那個前提是錯的，而名冊的代價是：App 啟動以來見過的
  /// 每個 thread 都被每 10 秒向 Hub 報到一次，早就結束的 session 被續命成
  /// ACTIVE——實測本機 4 個 lock、指派名單卻列出 11 個。已移除。
  Set<String> _localThreads() => activeThreadIds();

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

  int get pendingCount => _pending.length;

  /// 設定頁訂閱它把狀態顯示出來。純顯示用，沒有任何邏輯讀它。
  final ValueNotifier<CodexDispatchStatus> status =
      ValueNotifier(const CodexDispatchStatus());

  /// 重算計數並發布。[event] 給 null 時保留上一次的結果描述。
  void _publish([String? event]) {
    final busy = busyThreadIds();
    status.value = status.value.copyWith(
      pending: _pending.length,
      localThreads: _localThreads().length,
      busyThreads: busy.length,
      lastEvent: event,
    );
  }

  /// 板子動了。
  ///
  /// 與加入事件同一類：**狀態轉變，不是待辦**。所以做節流而不是佇列——
  /// 一個輪詢週期內第一則立刻送（對方馬上知道要去看），後續的合併成一則
  /// 在週期結束時送出。拖板子時一口氣十幾個 board_seq，逐則喚醒只是把
  /// 對方的 queue 塞滿同一件事。
  Future<void> handleBoardChange(String roomId, int boardSeq) async {
    if (!enabled) return;
    // 🔴 判斷與佔位**全部在第一個 await 之前**同步做完。
    //
    // `boardChanged.listen` 的 callback 是 unawaited 的，兩個事件會並行
    // 進來。把佔位放在 await 之後，那段空窗會讓兩邊都通過守門各送一次；
    // 更糟的是先送出的 seq=10 會被後完成的 seq=9 把水位寫回去
    // （Codex 09/14 審出——我前一版把佔位移到 await 之後，正是為了修
    // 另一個 bug，結果換來這個）。
    final previous = _lastBoardSent[roomId] ?? -1;
    if (boardSeq <= previous) {
      _log.info('board 變動略過（${_roomLabel(roomId)}）：'
          'seq $boardSeq 不新於已通知的 $previous');
      return; // 陳舊：不佔名額，後面真正新的變動才送得出去
    }
    if (_boardNoticedThisTick.contains(roomId)) {
      // 這個週期已經通知過了，留**最高**水位——並行進來的不保證由新到舊
      final pending = _pendingBoards[roomId] ?? -1;
      if (boardSeq > pending) _pendingBoards[roomId] = boardSeq;
      return;
    }
    _boardNoticedThisTick.add(roomId);
    _lastBoardSent[roomId] = boardSeq;
    var sent = false;
    try {
      sent = await _dispatchBoard(roomId, boardSeq);
    } catch (e, st) {
      _log.severe('board 通知失敗（$roomId）：$e', e, st);
    }
    if (!sent) _releaseBoardSlot(roomId, boardSeq, previous);
  }

  /// 沒送成就把名額與水位還回去，否則這一則變動從此沒有人會知道。
  ///
  /// 還原是安全的：佔位期間並行進來的事件都被正確地收進了 pending，
  /// 它們不會因為這次還原而漏掉。
  void _releaseBoardSlot(String roomId, int claimed, int previous) {
    _boardNoticedThisTick.remove(roomId);
    if (_lastBoardSent[roomId] != claimed) return; // 已經被更新的蓋過，別動
    if (previous < 0) {
      _lastBoardSent.remove(roomId);
    } else {
      _lastBoardSent[roomId] = previous;
    }
  }

  /// 純粹把通知送出去，回傳是否真的送成了。
  ///
  /// **守門（陳舊判斷、佔名額、推水位）一律在呼叫端同步做完**——放進來的話
  /// 又會落在 await 的另一側，那正是並行送兩次的成因。
  Future<bool> _dispatchBoard(String roomId, int boardSeq) async {
    final threads = threadOverride.isNotEmpty
        ? {threadOverride}
        : (await _roomRoutes(roomId)).values.expand((t) => t).toSet();
    if (threads.isEmpty) {
      _log.info('board 變動未投遞（${_roomLabel(roomId)}）：這個房裡沒有本機 Codex');
      return false;
    }
    final text =
        '[chatroom 通知] ${jsonEncode({
          'event': 'board_changed',
          'room_id': roomId,
          'room_name': _roomNames[roomId] ?? '',
          'board_seq': boardSeq,
          'action': '請呼叫 chatroom_board(room_id) 讀取變動——通知只說板子動了，不帶內容',
        })}';
    for (final thread in threads) {
      if (!await _queue(thread, text)) {
        _log.warning('codex queue 轉送失敗（board_changed, thread=$thread）');
      }
    }
    _publish('board 變動已投遞（${_roomLabel(roomId)} seq $boardSeq）');
    return true;
  }

  String _roomLabel(String roomId) {
    final name = _roomNames[roomId];
    return name == null || name.isEmpty ? roomId : name;
  }

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
    if (batch.roomName.isNotEmpty) _roomNames[batch.roomId] = batch.roomName;
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

    final busy = _scanBusyThreads();
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
    // 忙碌的 thread 只累積不投。`codex queue` 的 exit 0 只代表接受入列，
    // 而 CLI 沒有 replace/dedupe/cancel——在它處理 turn 的期間逐則入列，
    // 結果就是 turn 結束後逐筆倒灌，其中大半早已被 MCP 游標讀過。
    for (final entry in byThread.entries) {
      if (busy.contains(entry.key)) {
        _remember(batch, entry.value);
        continue;
      }
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
      // 🔴 忙碌期間**只喚醒一次**（原卡 1e3ce054）。`codex queue` 沒有
      // dedupe，turn 進行中每則加入都入列，結束後逐筆倒灌。
      //
      // ⚠️ 這裡刻意**不走 mention 那套「累積後補投」**：join 是狀態轉變，
      // 不是待辦。累積十分鐘再倒出來的那份名單，中間有人進了又走，
      // 送到時已經是錯的——而收到的人無從發現。
      //
      // 節流的形狀是：第一則照送（agent 立刻知道名錄變了，那正是這個通知
      // 的用途——它該去重查，不是把通知本身當名單讀），同一個 turn 內
      // 後續的抑制掉，turn 結束重置。
      if (busy.contains(entry.key) &&
          !_joinNoticedThisTurn.add(entry.key)) {
        _log.info(
          '加入事件抑制（$roomLabel，thread=${entry.key}）：'
          '這個 turn 已經通知過一次，${entry.value.length} 則不重複入列'
          '——它空下來會自己重查名錄',
        );
        continue;
      }
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
          'latest': {
            'seq': last.seq,
            'sender': last.senderName,
            'content': last.content,
            'mentions': last.mentions,
            // 附件只放 metadata（內容在 Hub 的磁碟上）。不放的話收到通知的
            // agent 根本不知道有東西要看——訊息正文常常只寫「你看得到這張
            // 圖嗎」，把附件略掉等於把問題本身略掉。
            if (last.attachments.isNotEmpty)
              'attachments': [
                for (final a in last.attachments)
                  {
                    'id': a.id,
                    'filename': a.filename,
                    'mime': a.mime,
                    'size': a.size,
                    'is_image': a.isImage,
                  },
              ],
          },
        })}';
    final ok = await _queue(thread, text);
    if (!ok) _log.warning('codex queue 轉送失敗（thread=$thread）');
    _publish(ok
        ? '已投遞 ${msgs.length} 則到 ${_shortThread(thread)}'
        : 'codex queue 失敗（${_shortThread(thread)}）');
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
    _publish('等 Codex 空下來（${_pending.length} 則待補投）');
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
      _publish('逾時放棄：${p.message.senderName} @ '
          '${p.message.mentions.join('、')}');
    }
    if (_pending.isEmpty) return;

    // 依房間分組重投：routes 是逐房查的
    final busy = _scanBusyThreads();
    final byRoom = <String, List<_PendingMention>>{};
    for (final p in _pending.values) {
      byRoom.putIfAbsent(p.roomId, () => []).add(p);
    }
    for (final entry in byRoom.entries) {
      final routes = await _roomRoutes(entry.key);
      if (routes.isEmpty) continue; // 從沒在本機見過這個房的 Codex，下一輪再說
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
        // 還在忙就繼續等。這一批合併成一次喚醒，等它空下來再送。
        if (busy.contains(t.key)) continue;
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
      // 每一輪都掃一次 lock，**不管有沒有東西要補投**。
      //
      // 🔴 加入通知的節流靠它重置，而 `flushPendingMentions` 佇列空就提早
      // 返回——把重置掛在那裡的話，「turn 結束了但剛好沒有待補的 mention」
      // 這個常態情況下節流永遠不解除，加入通知就從節流變成**永久靜音**。
      _scanBusyThreads();
      // 節流視窗以輪詢週期為單位：把這個週期內被合併掉的 board 變動送出去，
      // 然後開放下一個週期。先送再清，否則送出去的那一刻視窗已經開了，
      // 同一次變動可能被送兩遍。
      final coalesced = Map<String, int>.from(_pendingBoards);
      _pendingBoards.clear();
      // 名額在**進入迴圈前**就放開：期間並行進來的新變動該由 leading edge
      // 立刻送，不必等下一個週期
      _boardNoticedThisTick.clear();
      for (final entry in coalesced.entries) {
        final previous = _lastBoardSent[entry.key] ?? -1;
        if (entry.value <= previous) continue;
        _lastBoardSent[entry.key] = entry.value; // 同步佔住，理由同上
        var sent = false;
        try {
          sent = await _dispatchBoard(entry.key, entry.value);
        } catch (e) {
          _log.warning('board 合併通知失敗（${entry.key}）：$e');
        }
        if (!sent) _releaseBoardSlot(entry.key, entry.value, previous);
      }
      // 借同一個節奏補投 mention——投不出去的原因（Codex 沒在跑）與這裡
      // 要等的東西是同一件事
      try {
        await flushPendingMentions();
      } catch (e) {
        _log.warning('mention 補投失敗：$e');
      }
      // 🔴 走本機名冊而非 `activeThreadIds()`：後者只有忙著的 thread。
      // 用它輪詢的話，指派一個閒著的 Codex 要等它自己動起來才收得到，
      // 而且 `_fetchAssignments` 兼任向 Hub 報到——沒報到的 session 在
      // 指派 UI 上顯示成 idle，看起來像死了。
      for (final thread in _localThreads()) {
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
      // 計數要等所有增減都做完才發布：投遞成功那次的 `_publish` 發生在
      // 把訊息移出佇列**之前**，只靠它的話畫面會停在舊數字——而那正是
      // 這個面板要回答的問題。
      _publish();
    }
  }

  Future<Map<String, Set<String>>> _roomRoutes(String roomId) async {
    try {
      // lock 在就代表那個 Codex 進程還活著，這裡問的正是這件事。
      final local = _localThreads();
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

  /// thread id 太長，畫面上只顯示尾巴八碼（與指派 UI 的 label 同一套）。
  static String _shortThread(String t) =>
      t.length > 8 ? t.substring(t.length - 8) : t;

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
