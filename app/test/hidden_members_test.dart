import 'package:chatroom_app/core/config/app_settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 成員列表的隱藏名單。**純本機視圖**——不送去 Hub，不影響聊天內容、
/// mention、歷史或任何人的成員資料，所以這裡只驗儲存語意。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SettingsRepository settings;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    settings = SettingsRepository(await SharedPreferences.getInstance());
  });

  test('預設沒有隱藏任何人', () {
    expect(settings.hiddenMembers('r1'), isEmpty);
  });

  test('隱藏名單依房間分開存', () async {
    await settings.setHiddenMembers('r1', {'p1', 'p2'});
    await settings.setHiddenMembers('r2', {'p3'});
    expect(settings.hiddenMembers('r1'), {'p1', 'p2'});
    expect(settings.hiddenMembers('r2'), {'p3'});
    // 沒設過的房間不受影響——換房時拿錯名單會把不相干的人藏起來
    expect(settings.hiddenMembers('r3'), isEmpty);
  });

  test('清空時移除 key，不留一個空清單', () async {
    await settings.setHiddenMembers('r1', {'p1'});
    expect(settings.prefs.containsKey('chatroom.hidden_members.r1'), isTrue);
    await settings.setHiddenMembers('r1', {});
    expect(settings.hiddenMembers('r1'), isEmpty);
    expect(settings.prefs.containsKey('chatroom.hidden_members.r1'), isFalse);
  });

  test('取消隱藏只拿掉那一個人', () async {
    await settings.setHiddenMembers('r1', {'p1', 'p2', 'p3'});
    final next = settings.hiddenMembers('r1')..remove('p2');
    await settings.setHiddenMembers('r1', next);
    expect(settings.hiddenMembers('r1'), {'p1', 'p3'});
  });
}
