import 'dart:io';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:logging/logging.dart';

import 'notification_center.dart';

final _log = Logger('notifier');

/// OS 層通知（Windows toast / Android notification）。
///
/// 點擊通知 → [onSelectRoom]（由 app 層設定成導頁到該房間）。
/// 初始化失敗不致命：app 照常運作，只是沒有系統通知（記 log）。
class LocalNotifier {
  LocalNotifier._();

  static final LocalNotifier instance = LocalNotifier._();

  /// 點擊通知時的處理（payload = roomId）。app 建好 router 後指定。
  void Function(String roomId)? onSelectRoom;

  final _plugin = FlutterLocalNotificationsPlugin();
  bool _ready = false;
  int _nextId = 1;

  Future<void> init() async {
    if (_ready) return;
    try {
      const settings = InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        windows: WindowsInitializationSettings(
          appName: 'Chatroom',
          appUserModelId: 'UEP.Chatroom.App',
          guid: '7ff7b54d-fe7a-42dd-9e2c-921a9206140c',
        ),
      );
      await _plugin.initialize(
        settings,
        onDidReceiveNotificationResponse: (response) {
          final roomId = response.payload;
          if (roomId != null && roomId.isNotEmpty) {
            onSelectRoom?.call(roomId);
          }
        },
      );
      if (Platform.isAndroid) {
        // Android 13+ 通知需要 runtime 權限；拒絕就安靜退化成無通知
        await _plugin
            .resolvePlatformSpecificImplementation<
                AndroidFlutterLocalNotificationsPlugin>()
            ?.requestNotificationsPermission();
      }
      _ready = true;
    } catch (e) {
      _log.warning('通知初始化失敗（app 照常運作，僅無系統通知）：$e');
    }
  }

  Future<void> show(RoomNotification n) async {
    if (!_ready) return;
    try {
      await _plugin.show(
        _nextId++,
        n.mentioned ? '${n.roomName}（有人提及你）' : n.roomName,
        n.body,
        const NotificationDetails(
          android: AndroidNotificationDetails(
            'chatroom_messages',
            '聊天室訊息',
            channelDescription: '聊天室新訊息與提及通知',
            importance: Importance.high,
            priority: Priority.high,
          ),
          windows: WindowsNotificationDetails(),
        ),
        payload: n.roomId,
      );
    } catch (e) {
      _log.warning('通知送出失敗：$e');
    }
  }
}
