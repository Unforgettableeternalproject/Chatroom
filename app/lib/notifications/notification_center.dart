import 'dart:async';

import '../core/config/app_settings.dart';
import '../models/message.dart';
import '../ws/room_feed.dart';

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
  NotificationCenter(this._subscribe, this._unsubscribe);

  final RoomFeed Function(String roomId) _subscribe;
  final void Function(String roomId) _unsubscribe;

  NotifyModePref mode = NotifyModePref.all;
  String? activeRoomId;
  bool foreground = true;

  final Map<String, _FollowedRoom> _rooms = {};

  final _notifications = StreamController<RoomNotification>.broadcast();
  final _activity = StreamController<String>.broadcast();

  /// 該送去 OS 的通知（已套用模式與抑制規則）。
  Stream<RoomNotification> get notifications => _notifications.stream;

  /// 房間有新的非自己訊息（不論通知與否）——未讀提示刷新用。
  Stream<String> get activity => _activity.stream;

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
      return;
    }
    final feed = _subscribe(roomId);
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
  }

  /// 停止跟隨不在 [keep] 內的房間（房間封存/被移出時收掉）。
  void retainOnly(Set<String> keep) {
    for (final roomId in _rooms.keys.where((r) => !keep.contains(r)).toList()) {
      _drop(roomId);
    }
  }

  void _drop(String roomId) {
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
      return;
    }
    if (feed.cursor <= baseline) return;
    room.notifiedUpTo = feed.cursor;

    final fresh = <Message>[];
    for (final m in feed.messages) {
      if (m.seq <= baseline) continue;
      if (m.isSystem || m.deleted) continue;
      if (room.myParticipantId != null && m.senderId == room.myParticipantId) {
        continue;
      }
      fresh.add(m);
    }
    if (fresh.isEmpty) return;

    if (!_activity.isClosed) _activity.add(roomId);

    if (mode == NotifyModePref.off) return;
    final myName = room.myDisplayName;
    final mentioned = myName != null &&
        fresh.any((m) => m.mentions.contains(myName));
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
