import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/notifications_api.dart';
import '../core/config/app_settings.dart';
import '../core/errors/api_exception.dart';
import '../models/app_notification.dart';
import '../ws/inbox_socket.dart';
import '../ws/ws_protocol.dart';
import 'app_providers.dart';

final notificationsApiProvider = Provider<NotificationsApi>(
  (ref) => NotificationsApi(ref.watch(dioProvider)),
);

/// `/ws/inbox` 的連線。server／token／主持人模式任一變動就重連
/// （主持人模式決定收到哪些通知，理由同 `realtimeServiceProvider`）。
final inboxSocketProvider = Provider<InboxSocket>((ref) {
  final config =
      ref.watch(appConfigProvider.select((c) => (c.serverUrl, c.token)));
  final hostView = ref.watch(hostViewProvider);
  final sessionKey = ref.watch(appConfigProvider.select((c) => c.deviceKey));
  final socket = InboxSocket(
    uriBuilder: () => WsProtocol.wsUri(config.$1, config.$2,
        hostView: hostView, path: '/ws/inbox', sessionKey: sessionKey),
  );
  // 沒設定 server 就不連：空位址只會一直握手失敗再退避
  if (config.$1.isNotEmpty) socket.start();
  ref.onDispose(() => unawaited(socket.dispose()));
  return socket;
});

/// 通知頁是否正開著。開著且 App 在前景時不跳 OS 通知。
final notificationsPageOpenProvider =
    NotifierProvider<NotificationsPageOpen, bool>(NotificationsPageOpen.new);

class NotificationsPageOpen extends Notifier<bool> {
  @override
  bool build() => false;

  void set(bool open) {
    // 頁面的 dispose 延後一拍才呼叫，那時 provider 可能已隨容器釋放
    if (ref.mounted) state = open;
  }
}

/// 該不該為一批新通知跳 OS 通知（純邏輯）。
///
/// - [seeded] 為 false（第一批只是歷史）不跳
/// - 通知模式 off 不跳；mentions 照跳——收件匣裡的東西都是衝著我來的，
///   「只通知被 @」限制的是一般聊天訊息
/// - 通知頁開著且 App 在前景：畫面本身就是通知
bool shouldToastInbox({
  required NotifyModePref mode,
  required bool foreground,
  required bool pageOpen,
  required bool seeded,
}) {
  if (!seeded) return false;
  if (mode == NotifyModePref.off) return false;
  if (foreground && pageOpen) return false;
  return true;
}

/// 一則通知的去重鍵。合併進新事件（id 不變，count／updated_at 變了）要再提醒一次。
String inboxKey(AppNotification n) => '${n.id}|${n.count}|${n.updatedAt}';

/// 從剛拉到的第一頁挑出「新的未讀」。[seen] 是已經處理過的鍵。
/// 回傳舊的在前，OS 通知列上最後一則才是最新的。
List<AppNotification> pickFreshInbox(
    List<AppNotification> page, Set<String> seen) {
  return [
    for (final n in page.reversed)
      if (n.unread && !seen.contains(inboxKey(n))) n,
  ];
}

class InboxState {
  const InboxState({
    this.unread = 0,
    this.items = const [],
    this.loading = false,
    this.loadingMore = false,
    this.hasMore = false,
    this.error,
  });

  final int unread;
  final List<AppNotification> items;
  final bool loading;
  final bool loadingMore;
  final bool hasMore;
  final Object? error;

  InboxState copyWith({
    int? unread,
    List<AppNotification>? items,
    bool? loading,
    bool? loadingMore,
    bool? hasMore,
    Object? error,
    bool clearError = false,
  }) =>
      InboxState(
        unread: unread ?? this.unread,
        items: items ?? this.items,
        loading: loading ?? this.loading,
        loadingMore: loadingMore ?? this.loadingMore,
        hasMore: hasMore ?? this.hasMore,
        error: clearError ? null : (error ?? this.error),
      );
}

const kInboxPageSize = 30;

/// 通知中心的狀態：未讀數（鈴鐺徽章）＋已載入的通知。
///
/// WS 事件進來：先更新未讀數，再重拉第一頁。合併進既有通知時 id 不變，
/// `latest_id` 不會動，所以不能只看它有沒有變。
class NotificationInbox extends Notifier<InboxState> {
  bool _seeded = false;
  bool _refreshing = false;
  bool _again = false;
  final Set<String> _seen = {};

  /// 「載入更多」拉回來的較舊頁。第一頁重拉時保留它們。
  List<AppNotification> _older = const [];
  final _fresh = StreamController<List<AppNotification>>.broadcast();

  /// 第一批之後才出現的新通知（OS 通知的來源）。
  Stream<List<AppNotification>> get fresh => _fresh.stream;

  String get _key => ref.read(appConfigProvider).deviceKey;
  NotificationsApi get _api => ref.read(notificationsApiProvider);

  @override
  InboxState build() {
    final socket = ref.watch(inboxSocketProvider);
    final eventSub = socket.events.listen(_onEvent);
    // 斷線期間錯過的通知：每次（重新）連上補拉一次
    final connSub = socket.connected.listen((_) => unawaited(refresh()));
    ref.onDispose(() {
      eventSub.cancel();
      connSub.cancel();
      _fresh.close();
    });
    _seeded = false;
    _seen.clear();
    _older = const [];
    Future.microtask(refresh);
    return const InboxState(loading: true);
  }

  void _onEvent(InboxEvent e) {
    state = state.copyWith(unread: e.unreadCount);
    unawaited(refresh());
  }

  /// 重拉第一頁。
  Future<void> refresh() async {
    // 同時只跑一次；跑的途中又來事件，結束後補跑一輪
    if (_refreshing) {
      _again = true;
      return;
    }
    _refreshing = true;
    try {
      do {
        _again = false;
        await _refreshOnce();
      } while (_again && ref.mounted);
    } finally {
      _refreshing = false;
    }
  }

  Future<void> _refreshOnce() async {
    final NotificationPage page;
    try {
      page = await _api.list(sessionKey: _key, limit: kInboxPageSize);
    } on ApiException catch (e) {
      // missing_actor：這個身分還沒有收件人，當作沒有通知，不報錯
      state = e.code == 'missing_actor'
          ? state.copyWith(loading: false, clearError: true)
          : state.copyWith(loading: false, error: e);
      return;
    } catch (e) {
      if (ref.mounted) state = state.copyWith(loading: false, error: e);
      return;
    }
    if (!ref.mounted) return;
    final fresh = _seeded ? pickFreshInbox(page.items, _seen) : const <AppNotification>[];
    for (final n in page.items) {
      _seen.add(inboxKey(n));
    }
    _seeded = true;
    final firstIds = {for (final n in page.items) n.id};
    final older = [
      for (final n in _older)
        if (!firstIds.contains(n.id)) n,
    ];
    state = state.copyWith(
      unread: page.unreadCount,
      items: [...page.items, ...older],
      loading: false,
      hasMore: _older.isNotEmpty
          ? state.hasMore
          : page.items.length >= kInboxPageSize,
      clearError: true,
    );
    if (fresh.isNotEmpty && !_fresh.isClosed) _fresh.add(fresh);
  }

  Future<void> loadMore() async {
    if (state.loadingMore || !state.hasMore || state.items.isEmpty) return;
    state = state.copyWith(loadingMore: true);
    try {
      final page = await _api.list(
        sessionKey: _key,
        limit: kInboxPageSize,
        beforeId: state.items.last.id,
      );
      for (final n in page.items) {
        _seen.add(inboxKey(n));
      }
      _older = [..._older, ...page.items];
      state = state.copyWith(
        unread: page.unreadCount,
        items: [...state.items, ...page.items],
        loadingMore: false,
        hasMore: page.items.length >= kInboxPageSize,
      );
    } catch (e) {
      state = state.copyWith(loadingMore: false, error: e);
    }
  }

  /// 標單則已讀。失敗只丟出去，由呼叫端決定要不要擋後續動作。
  Future<void> markRead(AppNotification n) async {
    if (!n.unread) return;
    await _api.markRead(sessionKey: _key, ids: [n.id]);
    _applyRead((x) => x.id == n.id, unread: state.unread > 0 ? state.unread - 1 : 0);
  }

  Future<void> markAllRead() async {
    await _api.markRead(sessionKey: _key, all: true);
    _applyRead((_) => true, unread: 0);
  }

  void _applyRead(bool Function(AppNotification) test, {required int unread}) {
    final now = DateTime.now().toUtc().toIso8601String();
    AppNotification mark(AppNotification x) =>
        x.unread && test(x) ? x.withReadAt(now) : x;
    _older = [for (final x in _older) mark(x)];
    state = state.copyWith(
      items: [for (final x in state.items) mark(x)],
      unread: unread,
    );
  }
}

final notificationInboxProvider =
    NotifierProvider<NotificationInbox, InboxState>(NotificationInbox.new);

/// 鈴鐺徽章的數字。
final inboxUnreadProvider =
    Provider<int>((ref) => ref.watch(notificationInboxProvider).unread);
