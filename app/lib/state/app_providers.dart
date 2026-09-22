import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/api_client.dart';
import '../api/assignments_api.dart';
import '../api/attachments_api.dart';
import '../api/export_api.dart';
import '../api/messages_api.dart';
import '../api/questions_api.dart';
import '../api/rooms_api.dart';
import '../api/tokens_api.dart';
import '../core/config/app_settings.dart';
import '../core/config/build_info.dart';
import '../core/errors/api_exception.dart';
import '../core/identity/device_identity.dart';
import '../core/window/window_tray.dart';
import '../ws/realtime_service.dart';
import '../ws/ws_protocol.dart';

/// 啟動時於 main() 以 override 注入實例。
final settingsRepoProvider = Provider<SettingsRepository>(
  (ref) => throw UnimplementedError('main() 必須 override settingsRepoProvider'),
);

/// app 全域設定的快照。secure storage 的值在啟動時讀出一次，
/// 之後的變更都經由 AppConfigNotifier 寫回並同步此快照。
@immutable
class AppConfig {
  const AppConfig({
    required this.serverUrl,
    required this.token,
    required this.themeMode,
    required this.preferredName,
    required this.deviceKey,
    this.fontScale = FontScalePref.medium,
    this.fontFamily = FontFamilyPref.standard,
    this.locale = LocalePref.system,
    this.closeToTray = true,
    this.notifyModeRevision = 0,
  });

  /// 從已載入的設定倉庫組一份初始快照（啟動路徑用）。
  ///
  /// token 與 deviceKey 要 await 才拿得到，所以仍由呼叫端傳進來；
  /// 其餘偏好一律從這裡讀，新增欄位時不必再改一次啟動程式。
  factory AppConfig.fromSettings(
    SettingsRepository settings, {
    required String token,
    required String deviceKey,
  }) =>
      AppConfig(
        serverUrl: settings.serverUrl,
        token: token,
        themeMode: settings.themeMode,
        preferredName: settings.preferredName,
        deviceKey: deviceKey,
        fontScale: settings.fontScale,
        fontFamily: settings.fontFamily,
        locale: settings.locale,
        closeToTray: settings.closeToTray,
      );

  final String serverUrl;
  final String token;
  final ThemeModePref themeMode;
  final String preferredName;
  final String deviceKey;

  /// 字級偏好；套用在 `app.dart` 的 MediaQuery textScaler。
  final FontScalePref fontScale;

  /// 字體偏好；套用在 `app.dart`（寫進 `UepText.family`）。
  final FontFamilyPref fontFamily;

  /// 語言偏好；套用在 `app.dart` 的 MaterialApp.locale
  /// （`system` → 傳 null，交給 Flutter 依系統語言解析）。
  final LocalePref locale;

  /// 關閉視窗時縮到系統匣（Windows 專用）；套用在 `WindowTray`。
  final bool closeToTray;

  /// 通知模式改過幾次。**這裡不放模式本身**——它的權威在
  /// `SettingsRepository.notifyMode`，設定頁也直接讀那裡；在這邊再存一份
  /// 只會多出一個會過期的值。這個計數的用途只有一個：讓 widget 樹**之外**
  /// 改的通知模式（系統匣選單）也能觸發畫面重繪。要當前值請讀倉庫。
  final int notifyModeRevision;

  bool get isConfigured => serverUrl.isNotEmpty;

  AppConfig copyWith({
    String? serverUrl,
    String? token,
    ThemeModePref? themeMode,
    String? preferredName,
    String? deviceKey,
    FontScalePref? fontScale,
    FontFamilyPref? fontFamily,
    LocalePref? locale,
    bool? closeToTray,
    int? notifyModeRevision,
  }) =>
      AppConfig(
        serverUrl: serverUrl ?? this.serverUrl,
        token: token ?? this.token,
        themeMode: themeMode ?? this.themeMode,
        preferredName: preferredName ?? this.preferredName,
        deviceKey: deviceKey ?? this.deviceKey,
        fontScale: fontScale ?? this.fontScale,
        fontFamily: fontFamily ?? this.fontFamily,
        locale: locale ?? this.locale,
        closeToTray: closeToTray ?? this.closeToTray,
        notifyModeRevision: notifyModeRevision ?? this.notifyModeRevision,
      );
}

/// 啟動時載好的初始設定，main() override。
final initialConfigProvider = Provider<AppConfig>(
  (ref) => throw UnimplementedError('main() 必須 override initialConfigProvider'),
);

class AppConfigNotifier extends Notifier<AppConfig> {
  @override
  AppConfig build() {
    // 系統匣選單也能改通知模式，而它活在 widget 樹之外拿不到 ref
    WindowTray.instance
      ..notifyModeReader = (() => _settings.notifyMode)
      ..notifyModeWriter = setNotifyMode;
    return ref.watch(initialConfigProvider);
  }

  SettingsRepository get _settings => ref.read(settingsRepoProvider);

  Future<void> setServer({required String url, required String token}) async {
    await _settings.setServerUrl(url);
    await _settings.writeToken(token);
    state = state.copyWith(serverUrl: url.trim(), token: token);
  }

  Future<void> setThemeMode(ThemeModePref mode) async {
    await _settings.setThemeMode(mode);
    state = state.copyWith(themeMode: mode);
  }

  Future<void> toggleTheme() => setThemeMode(
      state.themeMode == ThemeModePref.dark
          ? ThemeModePref.light
          : ThemeModePref.dark);

  Future<void> setFontScale(FontScalePref scale) async {
    await _settings.setFontScale(scale);
    state = state.copyWith(fontScale: scale);
  }

  Future<void> setFontFamily(FontFamilyPref family) async {
    await _settings.setFontFamily(family);
    state = state.copyWith(fontFamily: family);
  }

  /// 關閉視窗→縮到系統匣。落盤之後**立刻套用**到 WindowTray：這個開關
  /// 改的是關閉鍵的行為，等下次啟動才生效等於這一次關掉會關錯。
  Future<void> setCloseToTray(bool v) async {
    await _settings.setCloseToTray(v);
    await WindowTray.instance.setEnabled(v);
    state = state.copyWith(closeToTray: v);
  }

  /// 通知模式。只寫倉庫並推一次 revision——**這裡不碰通知中心**：它經
  /// realtime 反過來依賴這顆 provider，從這裡讀會是循環相依。真正讓它
  /// 立刻生效的是 `notificationBootstrapProvider` 對 revision 的 listen。
  ///
  /// 設定頁自己那顆下拉目前仍直接寫倉庫（那個檔案這輪不歸我動），所以
  /// 兩條路都會經過倉庫；revision 只讓樹外改的那條能重繪。
  Future<void> setNotifyMode(NotifyModePref mode) async {
    await _settings.setNotifyMode(mode);
    state = state.copyWith(
        notifyModeRevision: state.notifyModeRevision + 1);
  }

  Future<void> setLocale(LocalePref pref) async {
    await _settings.setLocale(pref);
    state = state.copyWith(locale: pref);
  }

  Future<void> setPreferredName(String name) async {
    await _settings.setPreferredName(name);
    state = state.copyWith(preferredName: name.trim());
  }

  Future<void> regenerateDeviceKey() async {
    final key = await DeviceIdentity(_settings).regenerate();
    state = state.copyWith(deviceKey: key);
  }
}

final appConfigProvider =
    NotifierProvider<AppConfigNotifier, AppConfig>(AppConfigNotifier.new);

/// 「關閉視窗縮到系統匣」在這台機器上有沒有意義（只有 Windows 有）。
///
/// 做成 provider 而不是直接讀 `Platform`：理由同 `kitInstallSupportedProvider`
/// ——測試要能兩邊都測，而跑測試那台機器的作業系統不是被測的條件。
final closeToTraySupportedProvider =
    Provider<bool>((ref) => WindowTray.instance.supported);

// ---------- API ----------

/// 主持人模式開關。**預設關**——持主 token 不等於隨時在用那個身分。
///
/// 這是「明確切換」的 client 這一半：Hub 只在請求帶著 `X-Host-View` 時才
/// 用主持人身分放行，而那個標頭由這個 provider 決定要不要帶。開關關著時
/// App 的行為與任何一般使用者完全一樣。
///
/// 刻意**不持久化**：主持人視角看得到所有人的私人房，讓它跨重啟活著等於
/// 悄悄變成預設值。每次開 App 要重新打開，那個摩擦是刻意的。
final hostViewProvider = NotifierProvider<HostViewNotifier, bool>(
    HostViewNotifier.new);

class HostViewNotifier extends Notifier<bool> {
  @override
  bool build() => false;

  void set(bool on) => state = on;
  void toggle() => state = !state;
}

final dioProvider = Provider((ref) {
  final config = ref.watch(
      appConfigProvider.select((c) => (c.serverUrl, c.token)));
  // hostView 用 read 不用 watch：watch 會讓每次切換都重建 dio（連線一起
  // 關掉），而 interceptor 是每次請求現讀的，不需要重建
  final dio = createApiDio(
    baseUrl: config.$1,
    token: config.$2,
    hostView: () => ref.read(hostViewProvider),
  );
  ref.onDispose(dio.close);
  return dio;
});

final roomsApiProvider = Provider((ref) => RoomsApi(ref.watch(dioProvider)));
final messagesApiProvider =
    Provider((ref) => MessagesApi(ref.watch(dioProvider)));
final assignmentsApiProvider =
    Provider((ref) => AssignmentsApi(ref.watch(dioProvider)));
final exportApiProvider = Provider((ref) => ExportApi(ref.watch(dioProvider)));
final attachmentsApiProvider =
    Provider((ref) => AttachmentsApi(ref.watch(dioProvider)));
final questionsApiProvider =
    Provider((ref) => QuestionsApi(ref.watch(dioProvider)));
final tokensApiProvider =
    Provider((ref) => TokensApi(ref.watch(dioProvider)));

/// Hub 自報的 build 資訊（`{version, commit, built_at, source}`）。
///
/// 這整套機制的用途只有一個：讓「手上跑的是哪一份程式碼」變成一個可以回答
/// 的問題。今天的事故成本就是沒有人答得出來——測試端拿著 16 小時前的產物
/// 驗收，而三個人用三種方法去猜，全都在猜。
///
/// ⚠️ **原始的 build map 要留著，不能只留比對結果。**「對不上」這個結論
/// 回答不了「哪一邊舊」，而回報問題的人需要的正是兩邊的 commit。
///
/// 連不上 Hub、或舊版 Hub 不回這一段時是 null——null **不等於相符**，由
/// [BuildInfo.compare] 判成 [VersionMatch.unknown]。
final hubBuildProvider = FutureProvider<Map<String, dynamic>?>((ref) async {
  // 🔴 **斷線重連之後要重新判斷。**
  //
  // 這個 provider 原本這輩子只算一次，沒有任何東西 invalidate 它——於是
  // 升級 Hub 之後那條橫幅會一直掛著，直到使用者重啟整個 App。而**重啟 App
  // 正是他剛做完的事**（他更新了東西），所以那條橫幅在他眼裡是「我明明更新
  // 了它還在說我沒更新」。
  //
  // 用「連線由斷轉為 Connected」當觸發點：Hub 更新必然重啟，重啟必然斷 WS。
  // 那個時刻比任何輪詢都準，而且不花額外的請求。
  //
  // ⚠️ **用 `listen` 不用 `watch`**：watch 會讓每次狀態變化都重建，包含
  // 斷線那一刻——那時 health 打不通會回 unknown，等於把「連不上」偽裝成
  // 版本問題，正是底下那行註解在防的事。
  ref.listen(connectionStatusProvider, (previous, next) {
    final wasConnected = previous?.value is Connected;
    if (!wasConnected && next.value is Connected) {
      ref.invalidateSelf();
    }
  });

  final api = ref.watch(roomsApiProvider);
  try {
    final health = await api.health();
    return health.build;
  } on ApiException {
    // 連不上 Hub 是另一回事，不要偽裝成版本問題
    return null;
  }
});

/// 這份 App 自己的 build 識別。
///
/// 值在編譯期由 `--dart-define` 固定，執行期改不了——包成 provider 只是為了
/// 讓測試餵得進一份有 commit 的產物（測試環境沒有那些 define，
/// `BuildInfo.current.commit` 永遠是空的）。
final appBuildProvider = Provider<BuildInfo>((ref) => BuildInfo.current);

/// Hub 與本機 App 的比對結果。
///
/// 只做比對，不再自己去問 Hub——問的那一次在 [hubBuildProvider]，兩者共用
/// 同一次 health 請求（重連時的重算也在那裡）。
final versionMatchProvider = FutureProvider<VersionMatch>((ref) async {
  final hubBuild = await ref.watch(hubBuildProvider.future);
  return BuildInfo.compare(ref.watch(appBuildProvider), hubBuild);
});

// ---------- Realtime ----------

/// server/token 變更時整個 service 重建（舊連線 dispose、新連線重掛）。
final realtimeServiceProvider = Provider((ref) {
  final config = ref.watch(
      appConfigProvider.select((c) => (c.serverUrl, c.token)));
  // 主持人模式**要 watch**（不像 dio 那樣 read）：WS 的授權是在連線與
  // subscribe 當下決定的，切換模式必須重連才會生效。不重連的話開關看起來
  // 有反應（REST 立刻變了）但即時通道還停在舊身分上
  final hostView = ref.watch(hostViewProvider);
  final service = RealtimeService(
    messagesApi: ref.watch(messagesApiProvider),
    wsUriBuilder: () =>
        WsProtocol.wsUri(config.$1, config.$2, hostView: hostView),
  );
  service.start();
  ref.onDispose(() => service.dispose());
  return service;
});

final connectionStatusProvider = StreamProvider<RealtimeStatus>((ref) async* {
  final service = ref.watch(realtimeServiceProvider);
  yield service.status;
  yield* service.statusStream;
});
