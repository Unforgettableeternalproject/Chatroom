import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/api_client.dart';
import '../api/assignments_api.dart';
import '../api/attachments_api.dart';
import '../api/messages_api.dart';
import '../api/questions_api.dart';
import '../api/rooms_api.dart';
import '../api/tokens_api.dart';
import '../core/config/app_settings.dart';
import '../core/config/build_info.dart';
import '../core/errors/api_exception.dart';
import '../core/identity/device_identity.dart';
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
  });

  final String serverUrl;
  final String token;
  final ThemeModePref themeMode;
  final String preferredName;
  final String deviceKey;

  bool get isConfigured => serverUrl.isNotEmpty;

  AppConfig copyWith({
    String? serverUrl,
    String? token,
    ThemeModePref? themeMode,
    String? preferredName,
    String? deviceKey,
  }) =>
      AppConfig(
        serverUrl: serverUrl ?? this.serverUrl,
        token: token ?? this.token,
        themeMode: themeMode ?? this.themeMode,
        preferredName: preferredName ?? this.preferredName,
        deviceKey: deviceKey ?? this.deviceKey,
      );
}

/// 啟動時載好的初始設定，main() override。
final initialConfigProvider = Provider<AppConfig>(
  (ref) => throw UnimplementedError('main() 必須 override initialConfigProvider'),
);

class AppConfigNotifier extends Notifier<AppConfig> {
  @override
  AppConfig build() => ref.watch(initialConfigProvider);

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

// ---------- API ----------

final dioProvider = Provider((ref) {
  final config = ref.watch(
      appConfigProvider.select((c) => (c.serverUrl, c.token)));
  final dio = createApiDio(baseUrl: config.$1, token: config.$2);
  ref.onDispose(dio.close);
  return dio;
});

final roomsApiProvider = Provider((ref) => RoomsApi(ref.watch(dioProvider)));
final messagesApiProvider =
    Provider((ref) => MessagesApi(ref.watch(dioProvider)));
final assignmentsApiProvider =
    Provider((ref) => AssignmentsApi(ref.watch(dioProvider)));
final attachmentsApiProvider =
    Provider((ref) => AttachmentsApi(ref.watch(dioProvider)));
final questionsApiProvider =
    Provider((ref) => QuestionsApi(ref.watch(dioProvider)));
final tokensApiProvider =
    Provider((ref) => TokensApi(ref.watch(dioProvider)));

/// Hub 的版本資訊與本機 App 的比對結果。
///
/// 這整套機制的用途只有一個：讓「手上跑的是哪一份程式碼」變成一個可以回答
/// 的問題。今天的事故成本就是沒有人答得出來——測試端拿著 16 小時前的產物
/// 驗收，而三個人用三種方法去猜，全都在猜。
final versionMatchProvider = FutureProvider<VersionMatch>((ref) async {
  final api = ref.watch(roomsApiProvider);
  try {
    final health = await api.health();
    return BuildInfo.compare(BuildInfo.current, health.build);
  } on ApiException {
    // 連不上 Hub 是另一回事，不要偽裝成版本問題
    return VersionMatch.unknown;
  }
});

// ---------- Realtime ----------

/// server/token 變更時整個 service 重建（舊連線 dispose、新連線重掛）。
final realtimeServiceProvider = Provider((ref) {
  final config = ref.watch(
      appConfigProvider.select((c) => (c.serverUrl, c.token)));
  final service = RealtimeService(
    messagesApi: ref.watch(messagesApiProvider),
    wsUriBuilder: () => WsProtocol.wsUri(config.$1, config.$2),
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
