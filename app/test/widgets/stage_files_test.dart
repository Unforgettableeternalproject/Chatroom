import 'package:chatroom_app/core/config/app_settings.dart';
import 'package:chatroom_app/core/theme/uep_theme.dart';
import 'package:chatroom_app/models/stage_file.dart';
import 'package:chatroom_app/state/app_providers.dart';
import 'package:chatroom_app/widgets/stage_files.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _file = StageFile(
  id: 'sf1',
  checklistId: 'c1',
  attachmentId: 'a1',
  filename: 'run.log',
  mime: 'text/plain',
  size: 900,
  addedBy: 'human:bernie',
  addedByName: '艾斯維爾',
  note: '這輪要對照的 log',
);

Widget _host(Widget child) => ProviderScope(
      overrides: [
        initialConfigProvider.overrideWithValue(const AppConfig(
          serverUrl: 'http://hub.test',
          token: 'tok',
          themeMode: ThemeModePref.dark,
          preferredName: 'Bernie',
          deviceKey: 'device-key',
        )),
      ],
      child: MaterialApp(
        theme: buildUepTheme(Brightness.dark),
        home: Scaffold(body: child),
      ),
    );

void main() {
  group('階段標題列的素材數', () {
    testWidgets('0 不顯示——沒有素材是常態，每一列都掛一個「素材 0」會讓真的有的那幾列不顯眼',
        (tester) async {
      await tester.pumpWidget(_host(const StageFileCount(count: 0)));

      expect(find.textContaining('素材'), findsNothing);
    });

    testWidgets('有素材時顯示數量', (tester) async {
      await tester.pumpWidget(_host(const StageFileCount(count: 3)));

      expect(find.text('素材 3'), findsOneWidget);
    });
  });

  group('素材清單', () {
    testWidgets('列出檔名、大小、掛的人與 note', (tester) async {
      await tester.pumpWidget(_host(const StageFilesList(
        boardId: 'b1',
        checklistId: 'c1',
        files: [_file],
        actions: null,
        participantId: 'p1',
      )));

      expect(find.text('run.log'), findsWidgets);
      // 大小在兩處都出現：附件元件那一列，以及素材自己的說明列。
      // 兩個都是刻意的——清單摺起來只看得到後者
      expect(find.text('900 B'), findsWidgets);
      expect(find.text('· 艾斯維爾 掛上'), findsOneWidget);
      expect(find.text('這輪要對照的 log'), findsOneWidget);
    });

    testWidgets('空列表不佔版面——缺鍵的舊 Hub 就是這個樣子', (tester) async {
      await tester.pumpWidget(_host(const StageFilesList(
        boardId: 'b1',
        checklistId: 'c1',
        files: [],
        actions: null,
      )));

      expect(find.byType(SizedBox), findsWidgets);
      expect(find.textContaining('run.log'), findsNothing);
    });

    testWidgets('沒有動作可用時不畫卸除鈕——按下去只會是一個必定失敗的請求',
        (tester) async {
      await tester.pumpWidget(_host(const StageFilesList(
        boardId: 'b1',
        checklistId: 'c1',
        files: [_file],
        actions: null,
        participantId: 'p1',
        readOnly: true,
      )));

      expect(find.byTooltip('從階段卸除'), findsNothing);
    });
  });
}
