import 'package:chatroom_app/core/config/app_settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 側欄「關注」名單：純本機偏好，依 Hub 位址與種類分開存。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SettingsRepository settings;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    settings = SettingsRepository(await SharedPreferences.getInstance());
    await settings.setServerUrl('http://hub-a:8787');
  });

  test('預設沒有關注任何項目', () {
    expect(settings.pinnedIds(PinKind.room), isEmpty);
    expect(settings.pinnedIds(PinKind.board), isEmpty);
  });

  test('關注與取消關注', () async {
    await settings.setPinned(PinKind.room, 'r1', true);
    await settings.setPinned(PinKind.room, 'r2', true);
    expect(settings.pinnedIds(PinKind.room), {'r1', 'r2'});
    await settings.setPinned(PinKind.room, 'r1', false);
    expect(settings.pinnedIds(PinKind.room), {'r2'});
  });

  test('房間與 Board 各自一份', () async {
    await settings.setPinned(PinKind.room, 'x', true);
    expect(settings.pinnedIds(PinKind.board), isEmpty);
  });

  test('換 Hub 不互相污染，切回來還在', () async {
    await settings.setPinned(PinKind.room, 'r1', true);
    await settings.setServerUrl('http://hub-b:8787');
    expect(settings.pinnedIds(PinKind.room), isEmpty);
    await settings.setPinned(PinKind.room, 'r9', true);
    await settings.setServerUrl('http://hub-a:8787');
    expect(settings.pinnedIds(PinKind.room), {'r1'});
  });

  test('key 格式與位址正規化', () async {
    expect(SettingsRepository.pinnedKey(PinKind.board, ' HTTP://Hub-A:8787/ '),
        'chatroom.pinned.board.http://hub-a:8787');
    await settings.setPinned(PinKind.board, 'b1', true);
    expect(settings.prefs.getStringList('chatroom.pinned.board.http://hub-a:8787'),
        ['b1']);
  });

  test('清空時移除 key；重複操作不出錯', () async {
    await settings.setPinned(PinKind.room, 'r1', true);
    await settings.setPinned(PinKind.room, 'r1', true);
    await settings.setPinned(PinKind.room, 'r1', false);
    await settings.setPinned(PinKind.room, 'r1', false);
    expect(
        settings.prefs.containsKey('chatroom.pinned.room.http://hub-a:8787'),
        isFalse);
  });
}
