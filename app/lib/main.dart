import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'core/config/app_settings.dart';
import 'core/identity/device_identity.dart';
import 'core/window/window_tray.dart';
import 'package:logging/logging.dart';
import 'package:window_manager/window_manager.dart';

import 'core/logging/redacting_logger.dart';
import 'state/app_providers.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  setupLogging();
  // 把落點自己寫進 log 的第一行——要人去翻檔案，就得先講得出檔案在哪
  Logger('startup').info('log 落檔：${logFile?.path ?? '（無可寫位置，只進 DevTools）'}');

  final settings = await SettingsRepository.load();
  final token = await settings.readToken() ?? '';
  final deviceKey = await DeviceIdentity(settings).ensureKey();

  final initialConfig =
      AppConfig.fromSettings(settings, token: token, deviceKey: deviceKey);

  // 系統匣（Windows）。要在 runApp 之前裝好：關閉攔截與匣圖示都是視窗
  // 層的東西，晚於第一次 build 才註冊的話，那段期間關閉鍵仍會直接結束
  if (WindowTray.instance.supported) {
    await windowManager.ensureInitialized();
    await WindowTray.instance.init(enabled: settings.closeToTray);
  }

  runApp(ProviderScope(
    overrides: [
      settingsRepoProvider.overrideWithValue(settings),
      initialConfigProvider.overrideWithValue(initialConfig),
    ],
    child: const ChatroomApp(),
  ));
}
