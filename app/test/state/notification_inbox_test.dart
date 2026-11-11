import 'dart:async';
import 'dart:convert';

import 'package:chatroom_app/api/notifications_api.dart';
import 'package:chatroom_app/core/config/app_settings.dart';
import 'package:chatroom_app/models/app_notification.dart';
import 'package:chatroom_app/state/app_providers.dart';
import 'package:chatroom_app/state/notification_inbox_providers.dart';
import 'package:chatroom_app/ws/inbox_socket.dart';
import 'package:chatroom_app/ws/reconnect_policy.dart';
import 'package:chatroom_app/ws/ws_client.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/app_config.dart';

class _ZeroPolicy extends ReconnectPolicy {
  @override
  Duration delayFor(int attempt) => Duration.zero;
}

class _FakeConn implements WsConnection {
  final _in = StreamController<dynamic>();
  bool closed = false;

  @override
  int? closeCode;

  @override
  Stream<dynamic> get stream => _in.stream;

  @override
  void send(String data) {}

  @override
  Future<void> close() async {
    closed = true;
    if (!_in.isClosed) await _in.close();
  }

  void push(Map<String, dynamic> e) => _in.add(jsonEncode(e));

  Future<void> drop({int? code}) async {
    closeCode = code;
    if (!_in.isClosed) await _in.close();
  }
}

class _FakeApi extends NotificationsApi {
  _FakeApi() : super(Dio());

  List<AppNotification> items = [];
  int unread = 0;
  final listCalls = <({int? beforeId, bool unreadOnly})>[];
  final marked = <List<int>>[];
  int markAllCalls = 0;

  @override
  Future<NotificationPage> list({
    required String sessionKey,
    bool unreadOnly = false,
    int limit = 30,
    int? beforeId,
  }) async {
    listCalls.add((beforeId: beforeId, unreadOnly: unreadOnly));
    if (beforeId != null) {
      final i = items.indexWhere((n) => n.id == beforeId);
      final rest = i < 0 ? <AppNotification>[] : items.sublist(i + 1);
      return NotificationPage(
          unreadCount: unread, items: rest.take(limit).toList());
    }
    return NotificationPage(
        unreadCount: unread, items: items.take(limit).toList());
  }

  @override
  Future<void> markRead({
    required String sessionKey,
    List<int> ids = const [],
    bool all = false,
  }) async {
    if (all) {
      markAllCalls++;
    } else {
      marked.add(ids);
    }
  }
}

AppNotification _n(int id, {String? readAt, int count = 1}) =>
    AppNotification(id: id, summary: '事件 $id', readAt: readAt, count: count);

void main() {
  late _FakeApi api;
  late _FakeConn conn;
  late InboxSocket socket;
  late ProviderContainer container;

  Future<void> settle() async {
    for (var i = 0; i < 5; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  setUp(() {
    api = _FakeApi();
    conn = _FakeConn();
    socket = InboxSocket(
      uriBuilder: () => Uri.parse('ws://hub.test/ws/inbox'),
      connector: (_) async => conn,
      policy: _ZeroPolicy(),
    );
    container = ProviderContainer(overrides: [
      initialConfigProvider.overrideWithValue(kTestInitialConfig),
      notificationsApiProvider.overrideWithValue(api),
      inboxSocketProvider.overrideWithValue(socket),
    ]);
  });

  tearDown(() async {
    container.dispose();
    await socket.dispose();
  });

  test('啟動時拉第一頁：未讀數與清單；首批不算「新通知」', () async {
    api
      ..unread = 2
      ..items = [_n(2), _n(1)];
    final fresh = <List<AppNotification>>[];
    container.listen(notificationInboxProvider, (_, _) {});
    container.read(notificationInboxProvider.notifier).fresh.listen(fresh.add);
    await settle();

    final s = container.read(notificationInboxProvider);
    expect(s.unread, 2);
    expect(s.items.map((n) => n.id), [2, 1]);
    expect(container.read(inboxUnreadProvider), 2);
    expect(fresh, isEmpty);
  });

  test('WS inbox 事件：先更新徽章，latest_id 變了才重拉並吐出新通知', () async {
    api
      ..unread = 1
      ..items = [_n(1)];
    container.listen(notificationInboxProvider, (_, _) {});
    final fresh = <List<AppNotification>>[];
    container.read(notificationInboxProvider.notifier).fresh.listen(fresh.add);
    await settle();
    socket.start();
    await settle();
    final before = api.listCalls.length;

    api
      ..unread = 2
      ..items = [_n(2), _n(1)];
    conn.push({'type': 'inbox', 'unread_count': 2, 'latest_id': 2});
    await settle();

    expect(container.read(inboxUnreadProvider), 2);
    expect(api.listCalls.length, greaterThan(before));
    expect(fresh.single.map((n) => n.id), [2]);

    // 合併進既有通知時 latest_id 不變，仍要重拉（未讀數與內容都可能變）
    final calls = api.listCalls.length;
    api
      ..unread = 5
      ..items = [_n(2, count: 2), _n(1)];
    conn.push({'type': 'inbox', 'unread_count': 5, 'latest_id': 2});
    await settle();
    expect(container.read(inboxUnreadProvider), 5);
    expect(api.listCalls.length, greaterThan(calls));
    expect(fresh.length, 2);
    expect(fresh.last.single.count, 2);
  });

  test('斷線重連後補拉一次，新連線的事件照常處理', () async {
    // 這個測試自己接兩條連線：第一條被 server 切掉，第二條是重連
    final second = _FakeConn();
    final conns = [conn, second];
    final s2 = InboxSocket(
      uriBuilder: () => Uri.parse('ws://hub.test/ws/inbox'),
      connector: (_) async => conns.removeAt(0),
      policy: _ZeroPolicy(),
    );
    final c2 = ProviderContainer(overrides: [
      initialConfigProvider.overrideWithValue(kTestInitialConfig),
      notificationsApiProvider.overrideWithValue(api),
      inboxSocketProvider.overrideWithValue(s2),
    ]);
    addTearDown(() async {
      c2.dispose();
      await s2.dispose();
    });
    api.items = [_n(1)];
    c2.listen(notificationInboxProvider, (_, _) {});
    s2.start();
    await settle();
    final calls = api.listCalls.length;

    api
      ..unread = 1
      ..items = [_n(2), _n(1)];
    await conn.drop();
    await settle();

    // 重連本身就補拉了一次（斷線期間的通知）
    expect(api.listCalls.length, greaterThan(calls));
    expect(c2.read(inboxUnreadProvider), 1);
    api.unread = 4;
    second.push({'type': 'inbox', 'unread_count': 4, 'latest_id': 2});
    await settle();
    expect(c2.read(inboxUnreadProvider), 4);
  });

  test('markRead 送 ids 並更新本地；markAllRead 送 all', () async {
    api
      ..unread = 2
      ..items = [_n(2), _n(1)];
    container.listen(notificationInboxProvider, (_, _) {});
    await settle();
    final notifier = container.read(notificationInboxProvider.notifier);

    await notifier.markRead(container.read(notificationInboxProvider).items[0]);
    expect(api.marked.single, [2]);
    var s = container.read(notificationInboxProvider);
    expect(s.unread, 1);
    expect(s.items[0].unread, isFalse);
    expect(s.items[1].unread, isTrue);

    await notifier.markAllRead();
    expect(api.markAllCalls, 1);
    s = container.read(notificationInboxProvider);
    expect(s.unread, 0);
    expect(s.items.every((n) => !n.unread), isTrue);
  });

  test('loadMore 用最後一筆的 id 當 before_id，且續接在後面', () async {
    api.items = [for (var i = 40; i > 0; i--) _n(i)];
    api.unread = 0;
    container.listen(notificationInboxProvider, (_, _) {});
    await settle();
    var s = container.read(notificationInboxProvider);
    expect(s.items.length, kInboxPageSize);
    expect(s.hasMore, isTrue);

    await container.read(notificationInboxProvider.notifier).loadMore();
    expect(api.listCalls.last.beforeId, 11);
    s = container.read(notificationInboxProvider);
    expect(s.items.length, 40);
    expect(s.hasMore, isFalse);
  });

  group('OS 通知條件', () {
    test('首批不跳、off 不跳、前景且通知頁開著不跳；其餘跳', () {
      bool t({
        NotifyModePref mode = NotifyModePref.all,
        bool foreground = true,
        bool pageOpen = false,
        bool seeded = true,
      }) =>
          shouldToastInbox(
              mode: mode,
              foreground: foreground,
              pageOpen: pageOpen,
              seeded: seeded);

      expect(t(), isTrue);
      expect(t(seeded: false), isFalse);
      expect(t(mode: NotifyModePref.off), isFalse);
      expect(t(mode: NotifyModePref.mentions), isTrue);
      expect(t(pageOpen: true), isFalse);
      // 通知頁開著但 App 在背景：照跳
      expect(t(pageOpen: true, foreground: false), isTrue);
      expect(t(foreground: false), isTrue);
    });

    test('pickFreshInbox：只挑沒見過的未讀，舊的在前；count 變了算新的', () {
      final seen = {inboxKey(_n(1)), inboxKey(_n(2))};
      final page = [
        _n(4),
        _n(3, readAt: 'x'),
        _n(2, count: 2),
        _n(1),
      ];
      final fresh = pickFreshInbox(page, seen);
      expect(fresh.map((n) => n.id), [2, 4]);
    });
  });
}
