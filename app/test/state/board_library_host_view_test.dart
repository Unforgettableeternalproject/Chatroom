import 'package:chatroom_app/api/board_api.dart';
import 'package:chatroom_app/core/config/app_settings.dart';
import 'package:chatroom_app/models/board.dart';
import 'package:chatroom_app/state/app_providers.dart';
import 'package:chatroom_app/state/board_providers.dart';
import 'package:chatroom_app/widgets/host_mode_toggle.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// 🔴 2026-09-05：**BOARDS 分頁按下主持人模式，banner 恆紅、清單不變。**
///
/// 標頭那一半是好的（`host_view_test.dart` 釘住 dio 每次請求現讀開關），
/// server 那一半也是好的（帶 `X-Host-View` 就回私人板，8787 實測）。
/// 壞的是中間那一段：**清單根本沒有重抓**——`boardLibraryProvider` 沒有
/// `watch` 開關，於是切換之後沿用的還是開關打開**之前**那次的回應。
///
/// 後果有兩層，而且第二層比第一層難查：
///
///   1. 清單不會多出別人的板——功能等於沒作用
///   2. 那份舊回應的 `host_view` 是 `false`，於是 banner 亮起
///      「伺服器沒有照做」——**指著一個完全無辜的方向**
///
/// 對照組就在隔壁：`roomListProvider`（`state/rooms_providers.dart`）有
/// 這一行，還寫了註解說明為什麼需要它。ROOMS 補了，BOARDS 漏了。
class _FakeBoardsApi extends BoardsApi {
  _FakeBoardsApi(this._hostViewNow) : super(Dio());

  /// 模擬 Hub：帶了標頭（＝開關開著）就用主持人視角回答。
  /// 標頭怎麼帶是 dio 那層的事，已由 `host_view_test.dart` 釘住。
  final bool Function() _hostViewNow;

  int calls = 0;

  @override
  Future<BoardListResult> list({
    required String sessionKey,
    String status = 'active',
    String outcome = '',
  }) async {
    calls++;
    final host = _hostViewNow();
    return BoardListResult(
      boards: [
        const BoardSummary(id: 'b1', name: '我自己的板'),
        // 主持人視角才看得到的那塊
        if (host) const BoardSummary(id: 'b2', name: '別人的私人板'),
      ],
      youAreHost: true,
      hostView: host,
    );
  }
}

void main() {
  late ProviderContainer container;
  late _FakeBoardsApi api;

  setUp(() {
    api = _FakeBoardsApi(() => container.read(hostViewProvider));
    container = ProviderContainer(overrides: [
      initialConfigProvider.overrideWithValue(const AppConfig(
        serverUrl: 'http://test',
        token: 'root-token',
        themeMode: ThemeModePref.dark,
        preferredName: 'Bernie',
        deviceKey: 'device-key',
      )),
      boardsApiProvider.overrideWithValue(api),
    ]);
    addTearDown(container.dispose);
  });

  test('🔴 切換主持人模式會重抓 Board Library', () async {
    // autoDispose：整個測試期間保持訂閱，模擬畫面還開著
    container.listen(boardLibraryProvider('active'), (_, _) {});

    final before = await container.read(boardLibraryProvider('active').future);
    expect(api.calls, 1);
    expect(before.hostView, isFalse);
    expect(before.boards, hasLength(1));

    container.read(hostViewProvider.notifier).toggle();

    final after = await container.read(boardLibraryProvider('active').future);
    expect(api.calls, 2,
        reason: '開關切了但清單沒重抓 ⇒ 看到的是切換前的答案，'
            '功能等於沒作用');
    expect(after.hostView, isTrue,
        reason: 'banner 的 warn 條件是 hostOn && !hostView——'
            '沿用舊回應的話它恆為真，會指著無辜的 server');
    expect(after.boards, hasLength(2), reason: '主持人視角要多出別人的板');
  });

  test('🔴 關掉開關同樣要重抓——不然別人的板會留在畫面上', () async {
    container.listen(boardLibraryProvider('active'), (_, _) {});

    container.read(hostViewProvider.notifier).toggle();
    final on = await container.read(boardLibraryProvider('active').future);
    expect(on.boards, hasLength(2));

    container.read(hostViewProvider.notifier).toggle();
    final off = await container.read(boardLibraryProvider('active').future);
    expect(off.boards, hasLength(1),
        reason: '關掉之後還留著別人的私人板，比沒有這個功能更糟');
    expect(off.hostView, isFalse);
  });

  group('🔴 重抓期間不能亮「伺服器沒有照做」', () {
    // 艾斯維爾 2026-09-06 實機：「切換按鈕會有一瞬間仍然是紅色並且顯示
    // 伺服器無回應的，非常快但是存在」。
    //
    // 切換的那一瞬間，手上那份清單**必然還是切換前的**（Riverpod 保留舊值
    // 直到新回應到達）⇒ `hostView` 是 false ⇒ 警告閃一下紅。
    //
    // 它不是誤報一個不存在的問題，是**拿過期的資料回答一個關於現在的
    // 問題**——而診斷訊號在資料過期時必須閉嘴，否則它自己就變成雜訊。
    test('重抓中（舊值還在）一律不亮', () {
      expect(hostModeWarn(on: true, loading: true, hostView: false), isFalse);
    });

    test('重抓完了還是 false → 那才真的是 server 沒照做', () {
      expect(hostModeWarn(on: true, loading: false, hostView: false), isTrue);
    });

    test('生效了就不亮，開關關著也不亮', () {
      expect(hostModeWarn(on: true, loading: false, hostView: true), isFalse);
      expect(hostModeWarn(on: false, loading: false, hostView: false), isFalse);
    });
  });
}
