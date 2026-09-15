import 'package:chatroom_app/api/rooms_api.dart';
import 'package:chatroom_app/core/config/app_settings.dart';
import 'package:chatroom_app/core/errors/api_exception.dart';
import 'package:chatroom_app/models/room.dart';
import 'package:chatroom_app/state/app_providers.dart';
import 'package:chatroom_app/state/board_providers.dart';
import 'package:chatroom_app/state/rooms_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 封存房要用哪一份房內身分。
///
/// 🔴 這是「封存房看不到 Board」的**真正**成因，比缺入口更深一層：
/// Hub 的 `join` 一開頭就擋封存房（409 `room_archived`），而讀 board 原本
/// 無條件走 `identityProvider`——那個 provider 每次都 join。所以就算把入口
/// 補回 app bar，點進去照樣是一張錯誤畫面。
///
/// 而封存只禁止**寫入**：Hub 的 board 讀取端點自己寫著「封存房照樣讀得到」。
/// 唯讀瀏覽需要的只是「我曾經是誰」，那份 id 就在本機。
Room _room(String status) => Room(
      id: 'r1',
      name: '測試房',
      topic: '',
      status: status,
      createdAt: '2026-09-01T00:00:00+00:00',
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('規則本人', () {
    test('🔴 封存房用本機既有的那份，不要 join', () {
      expect(savedIdentityForBoard(archived: true, saved: 'p-old'), 'p-old');
    });

    test('沒封存就照常 join——null 代表「走原本那條路」', () {
      // 對照組：修封存那條路不可以把正常房間一起改掉
      expect(savedIdentityForBoard(archived: false, saved: 'p-old'), isNull);
      expect(savedIdentityForBoard(archived: false, saved: null), isNull);
    });

    test('封存房而本機沒有身分：照實說，不要退回 join', () {
      // 退回 join 只會拿到一個講「聊天室已封存」的 409——那句話沒有回答
      // 「所以我為什麼看不到這塊板」
      expect(() => savedIdentityForBoard(archived: true, saved: null),
          throwsA(isA<ArchivedWithoutIdentityException>()));
      expect(() => savedIdentityForBoard(archived: true, saved: ''),
          throwsA(isA<ArchivedWithoutIdentityException>()));
    });

    test('這個例外不可以觸發自動 re-join', () {
      // ParticipantInvalidException 會讓 App 自己去 re-join，而封存房
      // re-join 一百次都會被同一個 409 擋下來
      try {
        savedIdentityForBoard(archived: true, saved: null);
        fail('應該要丟例外');
      } on ApiException catch (e) {
        expect(e, isNot(isA<ParticipantInvalidException>()));
        expect(e.code, 'archived_no_identity');
      }
    });
  });

  group('接線', () {
    late SettingsRepository settings;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      settings = SettingsRepository(await SharedPreferences.getInstance());
    });

    test('封存房的 board 身分走本機那份，全程沒有碰到 API', () async {
      await settings.setParticipantId('r1', 'p-old');
      final c = ProviderContainer(
        overrides: [
          settingsRepoProvider.overrideWithValue(settings),
          roomDetailProvider('r1').overrideWith((ref) async =>
              RoomDetail(room: _room('archived'), participants: const [])),
        ],
      );
      addTearDown(c.dispose);
      c.listen(boardParticipantIdProvider('r1'), (_, _) {},
          onError: (_, _) {});

      // 這個 container 裡沒有任何可用的 API。走得通就代表沒有經過 join
      expect(await c.read(boardParticipantIdProvider('r1').future), 'p-old');
    });
  });
}
