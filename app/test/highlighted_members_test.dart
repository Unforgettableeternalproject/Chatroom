import 'package:chatroom_app/core/config/app_settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 時間軸上的成員標記。與隱藏名單同一類（**純本機視圖**，不送 Hub、不影響
/// 任何人看到的內容），方向相反：隱藏是「別讓他佔位置」，標記是「別讓我
/// 漏看他」。這裡驗儲存語意；視覺那半在 message_bubble。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SettingsRepository settings;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    settings = SettingsRepository(await SharedPreferences.getInstance());
  });

  test('預設沒有標記任何人', () {
    expect(settings.highlightedMembers('r1'), isEmpty);
  });

  test('標記依房間分開存——同一個人在別的房裡不該跟著亮', () async {
    await settings.setHighlightedMembers('r1', {'p1', 'p2'});
    await settings.setHighlightedMembers('r2', {'p3'});
    expect(settings.highlightedMembers('r1'), {'p1', 'p2'});
    expect(settings.highlightedMembers('r2'), {'p3'});
  });

  test('清空會把鍵移掉，不留一個空清單', () async {
    await settings.setHighlightedMembers('r1', {'p1'});
    await settings.setHighlightedMembers('r1', {});
    expect(settings.highlightedMembers('r1'), isEmpty);
    expect(settings.prefs.containsKey('chatroom.highlighted_members.r1'),
        isFalse);
  });

  test('與隱藏名單各存各的——同一個人可以既被隱藏又被標記，'
      '兩者不該互相覆寫', () async {
    await settings.setHiddenMembers('r1', {'p1'});
    await settings.setHighlightedMembers('r1', {'p1'});
    expect(settings.hiddenMembers('r1'), {'p1'});
    expect(settings.highlightedMembers('r1'), {'p1'});
  });
}
