import 'dart:async';

import 'package:chatroom_app/api/rooms_api.dart';
import 'package:chatroom_app/state/app_providers.dart';
import 'package:chatroom_app/ws/realtime_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// 版本橫幅要在 Hub 重啟之後重新判斷。
///
/// 原本 `versionMatchProvider` 這輩子只算一次，沒有任何東西 invalidate 它
/// ——升級 Hub 之後橫幅會一直掛著直到重啟整個 App。而**重啟 App 正是使用者
/// 剛做完的事**，所以那條橫幅在他眼裡是「我明明更新了它還在說我沒更新」
/// （艾斯維爾 2026-09-11 在想法板報的）。
///
/// 這裡測的是「有沒有重新去問」，不是比對結果——比對本身 `BuildInfo.compare`
/// 已經有自己的測試，而重算與否才是這次修的東西。
class _CountingRoomsApi extends RoomsApi {
  _CountingRoomsApi() : super(Dio());

  int calls = 0;

  @override
  Future<HealthResult> health() async {
    calls++;
    return const HealthResult(
      ok: true,
      version: '1.2.1',
      build: {'version': '1.2.1', 'commit': 'deadbeef1234', 'source': 'git'},
    );
  }
}

void main() {
  late _CountingRoomsApi api;
  late StreamController<RealtimeStatus> status;

  setUp(() {
    api = _CountingRoomsApi();
    status = StreamController<RealtimeStatus>.broadcast();
  });

  tearDown(() => status.close());

  /// ⚠️ **要 `listen` 保活，不能只 `read`。**
  ///
  /// `container.read` 讀完就讓 provider 被回收，而 `ref.listen` 註冊的監聽
  /// 跟著一起沒了——那時測出來的「沒有重算」是**測試環境造成的**，不是
  /// 實作的問題。真實 App 裡 `VersionBanner` 用的是 `ref.watch`，provider
  /// 全程活著。
  ProviderContainer makeContainer() {
    final container = ProviderContainer(
      overrides: [
        roomsApiProvider.overrideWithValue(api),
        connectionStatusProvider.overrideWith((ref) => status.stream),
      ],
    );
    container.listen(versionMatchProvider, (_, _) {});
    container.listen(connectionStatusProvider, (_, _) {});
    return container;
  }

  test('🔴 重新連上之後要重新問一次 Hub 的版本', () async {
    final container = makeContainer();
    addTearDown(container.dispose);

    await container.read(versionMatchProvider.future);
    expect(api.calls, 1, reason: '第一次讀取應該問一次');

    // Hub 重啟：WS 先斷再連
    status.add(const Disconnected(reason: 'background'));
    await Future<void>.delayed(Duration.zero);
    status.add(Connected());
    await Future<void>.delayed(Duration.zero);

    await container.read(versionMatchProvider.future);
    expect(api.calls, 2,
        reason: '重新連上之後沒有重問——橫幅會停在舊結論直到 App 重啟');
  });

  test('⚠️ 斷線本身不重算', () async {
    // 斷線時打 health 必然失敗 → 回 unknown，等於把「連不上」偽裝成版本
    // 問題。原始碼那行註解防的就是這個
    final container = makeContainer();
    addTearDown(container.dispose);

    await container.read(versionMatchProvider.future);
    expect(api.calls, 1);

    status.add(const Disconnected(reason: 'background'));
    await Future<void>.delayed(Duration.zero);

    await container.read(versionMatchProvider.future);
    expect(api.calls, 1, reason: '斷線不該觸發重算');
  });

  test('⚠️ 中途的 Connecting / Syncing 不重算', () async {
    // 那兩個狀態下 Hub 還沒真的接上，問了也是白問
    final container = makeContainer();
    addTearDown(container.dispose);

    await container.read(versionMatchProvider.future);
    status.add(const Connecting());
    await Future<void>.delayed(Duration.zero);
    status.add(const Syncing());
    await Future<void>.delayed(Duration.zero);

    await container.read(versionMatchProvider.future);
    expect(api.calls, 1);
  });

  test('⚠️ 已經連著的狀態重複送達不會一直重算', () async {
    // status stream 可能因為別的原因重播同一個狀態；每次都重算等於變成輪詢
    final container = makeContainer();
    addTearDown(container.dispose);

    status.add(Connected());
    await Future<void>.delayed(Duration.zero);
    await container.read(versionMatchProvider.future);
    final afterFirst = api.calls;

    status.add(Connected());
    await Future<void>.delayed(Duration.zero);
    await container.read(versionMatchProvider.future);

    expect(api.calls, afterFirst, reason: '同一個狀態重複送達不該重算');
  });
}
