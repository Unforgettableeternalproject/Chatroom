import 'dart:async';

import '../core/config/app_settings.dart';
import '../models/message.dart';
import '../ws/room_feed.dart';

/// 一個房間的一批「新的非自己訊息」——未經通知模式/抑制過濾的原始事件，
/// 供 Codex 轉送等下游自行過濾（例如剔除 Codex 自己的發言防迴圈）。
class RoomFreshBatch {
  const RoomFreshBatch({
    required this.roomId,
    required this.roomName,
    required this.messages,
  });

  final String roomId;
  final String roomName;
  final List<Message> messages;
}

/// 要送到 OS 的一則通知（一個房間的一批新訊息合併成一則，避免轟炸）。
class RoomNotification {
  const RoomNotification({
    required this.roomId,
    required this.roomName,
    required this.body,
    required this.mentioned,
  });

  final String roomId;
  final String roomName;
  final String body;
  final bool mentioned;
}

/// 通知中心：跟隨「已加入的房間」的 feed，把新訊息轉成通知事件。
///
/// 純 Dart（不 import flutter），OS 通知與 UI 刷新由外層訂閱
/// [notifications] / [activity] 接手。設計約束：
/// - **首批快照不通知**：feed 初次載入的是歷史視窗，逐則通知等於轟炸。
///   基準線取第一次看到內容時的 cursor，之後的增量才算「新」。
///   （app 關閉期間的訊息因此不會補發通知——未讀紅點負責那一段。）
/// - 自己發的訊息、system 訊息、已刪除訊息不通知。
/// - 正在看的房間（[activeRoomId]）且 app 在前景（[foreground]）時不通知，
///   但仍發 [activity] 讓房間列表刷新。
class NotificationCenter {
  NotificationCenter(this._subscribe, this._unsubscribe, this._syncIdentity);

  final RoomFeed Function(String roomId, {String? participantId}) _subscribe;
  final void Function(String roomId) _unsubscribe;

  /// 只把身分同步給 server，**不**取得一份新的訂閱所有權。
  ///
  /// `subscribe()` 每呼叫一次 refCount 就 +1，而 `follow()` 是冪等的、
  /// 每次房間列表刷新都會被呼叫一遍。用 subscribe 補身分會讓 refCount
  /// 單向累積，`_drop()` 只減一次就永遠歸不了零——房間被移出或封存後
  /// 仍被背景訂閱著，而且完全沒有異狀可看。
  final void Function(String roomId, String participantId) _syncIdentity;

  NotifyModePref mode = NotifyModePref.all;
  String? activeRoomId;
  bool foreground = true;

  final Map<String, _FollowedRoom> _rooms = {};

  /// roomId → 這台裝置這次加入所產生的那則 join 訊息 id，尚未投遞者。
  ///
  /// Hub 在 join 回應之前就 post 了加入訊息，而首次進房的訂閱早於 join
  /// （`roomFeedProvider` 先以 null 身分訂閱，`identityProvider` 才 POST）。
  /// 所以那則常常已經在暖 feed 裡，接著被「首批快照只立基準線」當成歷史
  /// 吃掉——這是正常路徑，不是邊角案例。
  ///
  /// 用精確的 message id 而不是時間窗：時間窗要嘛依賴 Hub 與 client 的
  /// 時鐘一致（差幾分鐘就又是一個看不出來的失效），要嘛得放寬到會把歷史
  /// 加入事件重播一遍。id 精確、可去重、消費一次就沒了。
  final Map<String, String> _expectedJoins = {};

  final _notifications = StreamController<RoomNotification>.broadcast();
  final _activity = StreamController<String>.broadcast();
  final _fresh = StreamController<RoomFreshBatch>.broadcast();
  final _mentionsOfMe = StreamController<String>.broadcast();

  /// 該送去 OS 的通知（已套用模式與抑制規則）。
  Stream<RoomNotification> get notifications => _notifications.stream;

  /// 房間有新的非自己訊息（不論通知與否）——未讀提示刷新用。
  Stream<String> get activity => _activity.stream;

  /// 未過濾的新訊息批次（不受通知模式與正在看的房影響）。
  Stream<RoomFreshBatch> get fresh => _fresh.stream;

  /// 有人在這個房 @ 了我——**待辦事實，不是打擾**。
  ///
  /// 刻意不套 [notifications] 那三道抑制（通知模式 off、正在看這個房、
  /// app 在前景）：那些回答的是「現在該不該跳出來打斷你」，而工作列徽章
  /// 回答的是「還有幾件事等你處理」。共用同一組條件的後果是——兩個人在
  /// 同一個房裡對話時互相 @，徽章一次都不會亮，因為那正是「你正開著這個
  /// 房」的時候；而桌面平台的失焦事件並不可靠（[foreground] 可能一直是
  /// true），所以連「切到別的視窗」都救不回來。
  ///
  /// 真的在看的話，ChatScreen 會把這筆清掉——「看到了」由看的那一方認定，
  /// 不由發送的這一端預先替它決定。
  Stream<String> get mentionsOfMe => _mentionsOfMe.stream;

  Set<String> get followedRoomIds => _rooms.keys.toSet();

  /// 開始跟隨一個房間。重複呼叫會更新房名/身分（冪等）。
  void follow(
    String roomId, {
    required String roomName,
    String? myParticipantId,
    String? myDisplayName,
  }) {
    final existing = _rooms[roomId];
    if (existing != null) {
      existing
        ..roomName = roomName
        ..myParticipantId = myParticipantId
        ..myDisplayName = myDisplayName;
      // 身分可能是這次才拿到的（先跟房、join 完才有 id）——要傳下去，
      // 否則 server 那條訂閱永遠是匿名的，收不到指名給我的問題。
      // 走 _syncIdentity 而非 _subscribe：這裡已經持有訂閱了，再 subscribe
      // 一次只會把 refCount 灌高，見上面的說明。
      if (myParticipantId != null && myParticipantId.isNotEmpty) {
        _syncIdentity(roomId, myParticipantId);
      }
      return;
    }
    final feed = _subscribe(roomId, participantId: myParticipantId);
    final room = _FollowedRoom(
      feed: feed,
      roomName: roomName,
      myParticipantId: myParticipantId,
      myDisplayName: myDisplayName,
    );
    // 訂閱當下 feed 可能已有內容（30 秒保留期內回訪）：直接以現況為基準
    if (!feed.isEmpty || feed.cursor > 0) {
      room.notifiedUpTo = feed.cursor;
    }
    room.sub = feed.changes.listen((_) => _onFeedChange(roomId));
    _rooms[roomId] = room;
    // 訂閱先於 join 時，這次的加入訊息可能已經在暖 feed 裡了
    _flushExpectedJoin(roomId, room);
  }

  /// 登記「我這次加入產生了這則訊息」，它必須恰好被投遞一次。
  void expectJoin(String roomId, String? messageId) {
    if (messageId == null || messageId.isEmpty) return;
    _expectedJoins[roomId] = messageId;
    final room = _rooms[roomId];
    if (room != null) _flushExpectedJoin(roomId, room);
  }

  /// 那則加入訊息若已經躺在 feed 裡（被當成歷史），補投一次。
  /// 消費即移除，所以之後 WS 增量再送到也不會投第二次。
  void _flushExpectedJoin(String roomId, _FollowedRoom room) {
    final id = _expectedJoins[roomId];
    if (id == null) return;
    final found = room.feed.byId(id);
    if (found == null || !found.isMemberJoined) return;
    _expectedJoins.remove(roomId);
    if (!_fresh.isClosed) {
      _fresh.add(RoomFreshBatch(
          roomId: roomId, roomName: room.roomName, messages: [found]));
    }
  }

  /// 停止跟隨不在 [keep] 內的房間（房間封存/被移出時收掉）。
  void retainOnly(Set<String> keep) {
    for (final roomId in _rooms.keys.where((r) => !keep.contains(r)).toList()) {
      _drop(roomId);
    }
  }

  void _drop(String roomId) {
    _expectedJoins.remove(roomId);
    final room = _rooms.remove(roomId);
    if (room == null) return;
    room.sub?.cancel();
    _unsubscribe(roomId);
  }

  void _onFeedChange(String roomId) {
    final room = _rooms[roomId];
    if (room == null) return;
    final feed = room.feed;

    // 首批快照＝歷史，只立基準線
    final baseline = room.notifiedUpTo;
    if (baseline == null) {
      if (!feed.isEmpty || feed.cursor > 0) room.notifiedUpTo = feed.cursor;
      // 首批快照就是「被當成歷史」的那一刻——這次的加入訊息若在裡面，
      // 現在不撈就永遠沒人撈了
      _flushExpectedJoin(roomId, room);
      return;
    }
    if (feed.cursor <= baseline) return;
    room.notifiedUpTo = feed.cursor;

    // 兩份清單刻意分開。OS 通知與未讀提示要排除「自己發的」，但 Codex
    // 轉送不行——人類在這個 App 裡 @ 本機 Codex，正是它該轉送的那一則，
    // 而那則的 sender 就是自己。共用同一份過濾結果會讓本機 Codex 永遠
    // 收不到同一台機器上的人對它說的話。
    final everything = <Message>[];
    final fromOthers = <Message>[];
    for (final m in feed.messages) {
      if (m.seq <= baseline) continue;
      if (m.deleted) continue;
      if (m.isSystem) {
        // system 訊息不進 OS 通知也不算未讀，但「有人加入」要讓 dispatcher
        // 喚醒房內的本機 agent——用 App 當通知樞紐的 Codex 沒有自己的
        // watcher 進程，不放行就只有另外掛 watch.py 的 agent 收得到。
        // 只加進 everything，不進 fromOthers：後者是 OS 通知與未讀的來源。
        //
        // ⚠️ 這裡**不可以**用 myParticipantId 排除「自己加入」。這個「自己」
        // 指的是本機人類的 App 身分，而 fresh 的收件人是同一台機器上的
        // agent——人類加入房間，正是該通知本機 agent 的那一則。用人類的
        // self-filter 去砍 agent 的出口，就是 B1 那個 bug 換一個位置重演。
        // Codex 自己加入不必叫醒自己，那個排除在 CodexDispatcher 做，
        // 那裡才分得出哪個 thread 對應哪個加入者。
        if (m.isMemberJoined) {
          // 走正常增量路徑送到了，登記作廢，免得補投機制再送一次
          if (_expectedJoins[roomId] == m.id) _expectedJoins.remove(roomId);
          everything.add(m);
        }
        continue;
      }
      everything.add(m);
      if (room.myParticipantId != null && m.senderId == room.myParticipantId) {
        continue;
      }
      fromOthers.add(m);
    }
    if (everything.isNotEmpty && !_fresh.isClosed) {
      _fresh.add(RoomFreshBatch(
          roomId: roomId, roomName: room.roomName, messages: everything));
    }
    final fresh = fromOthers;
    if (fresh.isEmpty) return;

    if (!_activity.isClosed) _activity.add(roomId);

    // 被 @ 的事實先發出去，任何抑制之前——見 mentionsOfMe 的說明
    final myName = room.myDisplayName;
    final mentioned = myName != null &&
        fresh.any((m) => m.mentions.contains(myName));
    if (mentioned && !_mentionsOfMe.isClosed) _mentionsOfMe.add(roomId);

    if (mode == NotifyModePref.off) return;
    if (mode == NotifyModePref.mentions && !mentioned) return;
    // 正在看這個房且 app 在前景：畫面本身就是通知
    if (foreground && roomId == activeRoomId) return;

    if (!_notifications.isClosed) {
      _notifications.add(RoomNotification(
        roomId: roomId,
        roomName: room.roomName,
        body: _composeBody(fresh),
        mentioned: mentioned,
      ));
    }
  }

  static String _composeBody(List<Message> fresh) {
    final last = fresh.last;
    final sender = last.senderName ?? '（未知成員）';
    final preview = _preview(last.content);
    if (fresh.length == 1) return '$sender：$preview';
    return '${fresh.length} 則新訊息，最新—$sender：$preview';
  }

  static String _preview(String content) {
    final flat = content.replaceAll(RegExp(r'\s+'), ' ').trim();
    return flat.length > 80 ? '${flat.substring(0, 79)}…' : flat;
  }

  void dispose() {
    for (final roomId in _rooms.keys.toList()) {
      _drop(roomId);
    }
    _notifications.close();
    _activity.close();
    _fresh.close();
    _mentionsOfMe.close();
  }
}

class _FollowedRoom {
  _FollowedRoom({
    required this.feed,
    required this.roomName,
    this.myParticipantId,
    this.myDisplayName,
  });

  final RoomFeed feed;
  String roomName;
  String? myParticipantId;
  String? myDisplayName;

  /// 已處理到的 cursor；null = 尚未看過第一批快照。
  int? notifiedUpTo;
  StreamSubscription<void>? sub;
}
