import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'core/config/app_settings.dart';
import 'core/identity/device_identity.dart';
import 'package:logging/logging.dart';

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

  runApp(ProviderScope(
    overrides: [
      settingsRepoProvider.overrideWithValue(settings),
      initialConfigProvider.overrideWithValue(initialConfig),
    ],
    child: const ChatroomApp(),
  ));
}
