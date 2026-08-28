import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'core/config/app_settings.dart';
import 'core/identity/device_identity.dart';
import 'core/logging/redacting_logger.dart';
import 'state/app_providers.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  setupLogging();

  final settings = await SettingsRepository.load();
  final token = await settings.readToken() ?? '';
  final deviceKey = await DeviceIdentity(settings).ensureKey();

  final initialConfig = AppConfig(
    serverUrl: settings.serverUrl,
    token: token,
    themeMode: settings.themeMode,
    preferredName: settings.preferredName,
    deviceKey: deviceKey,
  );

  runApp(ProviderScope(
    overrides: [
      settingsRepoProvider.overrideWithValue(settings),
      initialConfigProvider.overrideWithValue(initialConfig),
    ],
    child: const ChatroomApp(),
  ));
}
