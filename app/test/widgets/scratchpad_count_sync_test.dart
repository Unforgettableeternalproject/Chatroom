import 'package:chatroom_app/api/scratchpad_api.dart';
import 'package:chatroom_app/core/config/app_settings.dart';
import 'package:chatroom_app/core/theme/uep_theme.dart';
import 'package:chatroom_app/models/scratchpad.dart';
import 'package:chatroom_app/screens/board/scratchpad_screen.dart';
import 'package:chatroom_app/state/app_providers.dart';
import 'package:chatroom_app/state/scratchpad_providers.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// 🔴 2026-09-04：**板頁上的「N 段」與想法板裡的段數對不上**
/// （艾斯維爾在想法板上的觀察）。
///
/// 同一份資料在兩個 provider 裡各有一份快照：清單那份（`scratchpadListProvider`
/// 的 `block_count`）與內容那份（`scratchpadProvider` 的 `blocks.length`）。
/// 寫入之後只重拉了內容那份 ⇒ 回到板頁，數字還是進來之前的。
///
/// ⚠️ 這種壞法**不像壞掉**：畫面上只是一個看起來有點怪的數字，沒有錯誤、
/// 沒有空白，所以它會一直留著沒人修。
class _CountingApi extends ScratchpadApi {
  _CountingApi() : super(Dio());

  int blocks = 1;
  int listCalls = 0;

  @override
  Future<List<ScratchpadSummary>> list(String boardId,
      {required String sessionKey}) async {
    listCalls++;
    return [
      ScratchpadSummary.fromJson(
          {'id': 'p1', 'title': '功能', 'block_count': blocks}),
    ];
  }

  @override
  Future<Scratchpad> fetch(String boardId, String padId,
          {required String sessionKey}) async =>
      Scratchpad.fromJson({
        'id': 'p1',
        'title': '功能',
        'rev': blocks,
        'can_edit': true,
        'i_am_human': true,
        'blocks': [
          for (var i = 0; i < blocks; i++)
            {'id': 'b$i', 'content': '第 $i 段', 'rev': 1, 'can_edit': true},
        ],
      });

  @override
  Future<String> addBlock(String boardId, String padId,
      {required String sessionKey,
      required String content,
      String afterBlockId = ''}) async {
    blocks++;
    return 'b$blocks';
  }
}

const _cfg = AppConfig(
  serverUrl: 'http://test',
  token: 't',
  themeMode: ThemeModePref.dark,
  preferredName: '我',
  deviceKey: 'k',
);

void main() {
  testWidgets('🔴 在想法板裡加一段，板頁上的段數也要跟著動', (tester) async {
    final api = _CountingApi();
    final container = ProviderContainer(overrides: [
      initialConfigProvider.overrideWithValue(_cfg),
      scratchpadApiProvider.overrideWithValue(api),
    ]);
    addTearDown(container.dispose);

    // 板頁先看過一次清單：這就是那個會過期的數字
    expect((await container.read(scratchpadListProvider('bd1').future))
        .single.blockCount, 1);
    expect(api.listCalls, 1);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildUepTheme(Brightness.dark),
        home: const Scaffold(
          body: ScratchpadScreen(boardId: 'bd1', padId: 'p1'),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byWidgetPredicate((w) =>
          w is TextField && w.decoration?.hintText == '再想到什麼就往這裡丟…'),
      '新的一段',
    );
    await tester.pump();
    await tester.tap(find.text('加一段'));
    await tester.pumpAndSettle();

    expect(api.blocks, 2, reason: '先確認真的送出去了，否則下面驗的是假的');
    expect(
      (await container.read(scratchpadListProvider('bd1').future)).single
          .blockCount,
      2,
      reason: '只重拉內容不重拉清單的話，這裡會停在 1',
    );
  });
}
