import 'package:chatroom_app/core/config/app_settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 工作列角標的數字綁在**未處理**上，不是**未讀**上。
///
/// 右下角的系統通知是會過去的——看漏一次就沒了，而使用者當下多半在別的
/// 視窗裡。徽章的價值在持續性：它留到那件事真的被處理掉為止。所以
/// 「看到了但沒答」不能讓數字減少，那正是使用者抱怨「容易被忽略」的成因。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SettingsRepository settings;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    settings = SettingsRepository(await SharedPreferences.getInstance());
  });

  group('未讀 mention 計數', () {
    test('預設為零', () {
      expect(settings.pendingMentions('r1'), 0);
      expect(settings.totalPendingMentions, 0);
    });

    test('每被 @ 一次加一，依房間分開累計', () async {
      await settings.addPendingMention('r1');
      await settings.addPendingMention('r1');
      await settings.addPendingMention('r2');

      expect(settings.pendingMentions('r1'), 2);
      expect(settings.pendingMentions('r2'), 1);
      expect(settings.totalPendingMentions, 3);
    });

    test('進到某個房間只清那一房——別房的還等著', () async {
      await settings.addPendingMention('r1');
      await settings.addPendingMention('r2');

      await settings.clearPendingMentions('r1');

      expect(settings.pendingMentions('r1'), 0);
      expect(settings.pendingMentions('r2'), 1);
      expect(settings.totalPendingMentions, 1);
    });

    test('計數要跨重啟保留——關掉 App 再開，那件事還在', () async {
      await settings.addPendingMention('r1');

      // 同一份 prefs 重新建一個 repository＝模擬重啟
      final reopened =
          SettingsRepository(await SharedPreferences.getInstance());

      expect(reopened.pendingMentions('r1'), 1);
    });

    test('與已讀 cursor 互不影響——看了不等於處理了', () async {
      await settings.addPendingMention('r1');
      await settings.setLastReadSeq('r1', 99);

      // 推進已讀游標不會動到 mention 計數：前者是「看到哪」，
      // 後者是「還有幾件等我」
      expect(settings.pendingMentions('r1'), 1);
    });

    test('清空時移除 key，不留一個 0 在裡面', () async {
      await settings.addPendingMention('r1');
      await settings.clearPendingMentions('r1');

      expect(settings.prefs.containsKey('chatroom.pending_mention.r1'), isFalse);
    });
  });
}
