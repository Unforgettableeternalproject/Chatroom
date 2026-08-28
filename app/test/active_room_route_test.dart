import 'package:chatroom_app/app.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

/// 通知抑制的依據是「當前路由」，不是「ChatScreen 還活著」。
///
/// 這兩件事會分岔：`/settings` 是 push 到根 Navigator，底下 ShellRoute 裡的
/// ChatScreen 不會 dispose，於是它繼續宣稱自己是 activeRoomId——使用者明明在
/// 看設定頁，所有通知卻被抑制（2026-08-29 實機發現：前景、在別的畫面、通知
/// 模式「全部訊息」，被 @mention 仍完全沒有通知）。
void main() {
  group('activeRoomIdFor', () {
    test('聊天畫面 → 該房抑制通知', () {
      expect(activeRoomIdFor('/rooms/abc123'), 'abc123');
    });

    test('房間列表 → 不抑制', () {
      expect(activeRoomIdFor('/rooms'), isNull);
    });

    test('設定頁 → 不抑制', () {
      expect(activeRoomIdFor('/settings'), isNull);
    });

    test('釘選牆與指派頁看不到訊息流 → 不抑制', () {
      expect(activeRoomIdFor('/rooms/abc123/pinned'), isNull);
      expect(activeRoomIdFor('/rooms/abc123/assign'), isNull);
    });
  });

  /// 上面的推導只有在「取得的路徑真的是最上層」時才有意義，而這一點不能靠
  /// 推論：`currentConfiguration.uri` 是 **base location**，push 疊上來的畫面
  /// 完全不反映在裡面（`/settings` 蓋住聊天室時它仍是 `/rooms/<id>`）。最上層
  /// 要從 `last.matchedLocation` 取——第一版就是照 `uri` 寫的，這個測試當場
  /// 抓到，否則等於沒修。
  testWidgets('push 蓋在 ShellRoute 之上時，最上層路由要能取到', (tester) async {
    final router = GoRouter(
      initialLocation: '/rooms',
      routes: [
        GoRoute(
          path: '/settings',
          builder: (_, _) => const Text('settings'),
        ),
        ShellRoute(
          builder: (a, b, child) => child,
          routes: [
            GoRoute(
              path: '/rooms',
              builder: (_, _) => const Text('rooms'),
              routes: [
                GoRoute(
                  path: ':roomId',
                  builder: (_, _) => const Text('chat'),
                  routes: [
                    GoRoute(
                      path: 'pinned',
                      builder: (_, _) => const Text('pinned'),
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ],
    );
    addTearDown(router.dispose);

    // 最上層＝last.matchedLocation。刻意不用 currentConfiguration.uri：
    // 那是 base location，push 上來的 /settings 不會出現在裡面。
    String path() =>
        router.routerDelegate.currentConfiguration.last.matchedLocation;

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    expect(activeRoomIdFor(path()), isNull);

    router.go('/rooms/r1');
    await tester.pumpAndSettle();
    expect(activeRoomIdFor(path()), 'r1');

    // 關鍵：push 不會 dispose 底下的 ChatScreen，但路由堆疊必須反映最上層
    router.push('/settings');
    await tester.pumpAndSettle();
    expect(activeRoomIdFor(path()), isNull,
        reason: '設定頁蓋在上面時該房必須恢復可通知');

    router.pop();
    await tester.pumpAndSettle();
    expect(activeRoomIdFor(path()), 'r1', reason: '回到聊天畫面後恢復抑制');

    router.go('/rooms/r1/pinned');
    await tester.pumpAndSettle();
    expect(activeRoomIdFor(path()), isNull);
  });
}
