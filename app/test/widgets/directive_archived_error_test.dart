import 'package:chatroom_app/api/board_api.dart';
import 'package:chatroom_app/core/config/app_settings.dart';
import 'package:chatroom_app/core/errors/api_exception.dart';
import 'package:chatroom_app/core/theme/uep_theme.dart';
import 'package:chatroom_app/models/board.dart';
import 'package:chatroom_app/screens/board/supervisor_panel.dart';
import 'package:chatroom_app/state/app_providers.dart';
import 'package:chatroom_app/state/board_providers.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// c81f757a 的 App 半邊：**directive 投到封存房，被送出端拒的時候要講對話。**
///
/// Server 半邊回既有契約的 409 `room_archived`（決策 2026-09-07 裁：不另造
/// 新 code）。而 `RoomArchivedException` 的預設訊息寫死「此聊天室已封存，
/// **無法發言**」——送指示的人沒有在發言，那句話對不上他做的事。
///
/// ⚠️ 更要緊的是**這次到底留下了什麼**。這個面板的成功路徑會說「已寫進
/// 稽核串，但對方不在任何掛接的聊天室裡」——那是「留下了、只是沒人被叫醒」。
/// 被拒是另一回事：**什麼都沒留下**。兩者混用同一句話，送的人會以為那句
/// 判斷已經在板上了。
class _ArchivedApi extends BoardsApi {
  _ArchivedApi() : super(Dio());

  @override
  Future<bool> sendDirective(
    String boardId, {
    required String sessionKey,
    required String text,
    String? targetActorKey,
    String? itemId,
    String? itemKind,
  }) async =>
      throw const RoomArchivedException();
}

const _cfg = AppConfig(
  serverUrl: 'http://test',
  token: 't',
  themeMode: ThemeModePref.dark,
  preferredName: '我',
  deviceKey: 'k',
);

BoardSnapshot _snap() => const BoardSnapshot().merge(BoardDelta.fromJson({
      'board_seq': 10,
      'full': true,
      'board_id': 'b1',
      'my_role': 'owner',
      'members': [
        {'actor_key': 'a1', 'display_name': '開發Novia (UI)', 'role': 'editor'},
      ],
    }));

void main() {
  testWidgets('🔴 送不進封存房時，要說出「什麼都沒留下」而不是「無法發言」',
      (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        initialConfigProvider.overrideWithValue(_cfg),
        boardsApiProvider.overrideWithValue(_ArchivedApi()),
        boardByIdProvider('b1').overrideWith((ref) async => _snap()),
      ],
      child: MaterialApp(
        theme: buildUepTheme(Brightness.dark),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showSupervisorPanel(context, boardId: 'b1'),
              child: const Text('開'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('開'));
    await tester.pumpAndSettle();

    // 挑收件者（廣播那一項）並寫一句話
    await tester.tap(find.byType(DropdownButtonFormField<String?>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('所有板成員（1）').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '這輪先收尾');
    await tester.pumpAndSettle();

    // 面板本身會捲（內容比 800×600 高），送出鈕預設落在視窗外
    await tester.ensureVisible(find.text('送出'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('送出'));
    await tester.pumpAndSettle();

    expect(find.text('這間房已封存，這則判斷沒有送出，也沒有留在稽核串上。'),
        findsOneWidget);
    // 寫死的那句對不上使用者做的事——他送的是判斷，不是發言
    expect(find.text('此聊天室已封存，無法發言'), findsNothing);
  });
}
