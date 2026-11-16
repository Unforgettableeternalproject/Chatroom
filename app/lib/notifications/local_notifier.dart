import 'dart:io';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:logging/logging.dart';

import '../l10n/l10n.dart';
import 'notification_center.dart';

final _log = Logger('notifier');

/// OS 層通知（Windows toast／macOS 通知中心／Linux 的 freedesktop
/// 通知／Android notification）。
///
/// 點擊通知 → [onSelectRoom]（由 app 層設定成導頁到該房間）。
/// 初始化失敗不致命：app 照常運作，只是沒有系統通知（記 log）。
class LocalNotifier {
  LocalNotifier._();

  static final LocalNotifier instance = LocalNotifier._();

  /// 點擊通知時的處理（payload = roomId，或 `path:` 開頭的站內路徑）。
  /// app 建好 router 後指定。
  void Function(String roomId)? onSelectRoom;

  final _plugin = FlutterLocalNotificationsPlugin();
  bool _ready = false;
  int _nextId = 1;

  Future<void> init() async {
    if (_ready) return;
    try {
      final settings = InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        windows: WindowsInitializationSettings(
          appName: 'Chatroom',
          appUserModelId: 'UEP.Chatroom.App',
          guid: '7ff7b54d-fe7a-42dd-9e2c-921a9206140c',
        ),
        // macOS：初始化時向系統要通知權限（拒絕＝安靜退化成沒有通知）。
        // 角標只有 Windows 工作列有做，所以不要角標權限。
        macOS: const DarwinInitializationSettings(
          requestAlertPermission: true,
          requestSoundPermission: true,
          requestBadgePermission: false,
        ),
        // Linux：走 D-Bus 的 org.freedesktop.Notifications；沒有通知服務時
        // initialize 會丟例外，由下面的 catch 接住（只是沒有系統通知）
        linux: const LinuxInitializationSettings(
          defaultActionName: 'Chatroom',
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
        n.mentioned
            ? L10n.current.notifyMentionedTitle(n.roomName)
            : n.roomName,
        n.body,
        NotificationDetails(
          android: AndroidNotificationDetails(
            'chatroom_messages',
            L10n.current.notifyChannelName,
            channelDescription: L10n.current.notifyChannelDesc,
            importance: Importance.high,
            priority: Priority.high,
          ),
          windows: const WindowsNotificationDetails(),
          macOS: const DarwinNotificationDetails(
            presentAlert: true,
            presentSound: true,
            presentBadge: false,
          ),
          linux: const LinuxNotificationDetails(),
        ),
        payload: n.target ?? n.roomId,
      );
    } catch (e) {
      _log.warning('通知送出失敗：$e');
    }
  }
}
