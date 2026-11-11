import 'package:chatroom_app/core/config/app_settings.dart';
import 'package:chatroom_app/state/app_providers.dart';

/// 直接掛 BoardScreen／RoomHeader 的測試用：這些畫面會 watch appConfigProvider
/// （開發者模式），沒有 override initialConfigProvider 就會拋 UnimplementedError。
final kTestInitialConfig = AppConfig(
  serverUrl: '',
  token: '',
  themeMode: ThemeModePref.dark,
  preferredName: '',
  deviceKey: 'test',
);
