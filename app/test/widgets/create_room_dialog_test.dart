import 'package:chatroom_app/api/rooms_api.dart';
import 'package:chatroom_app/core/config/app_settings.dart';
import 'package:chatroom_app/core/theme/uep_theme.dart';
import 'package:chatroom_app/models/board.dart';
import 'package:chatroom_app/models/room.dart';
import 'package:chatroom_app/screens/rooms/room_list_screen.dart';
import 'package:chatroom_app/state/app_providers.dart';
import 'package:chatroom_app/state/board_providers.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// 建房對話框的版面與房間類型。
///
/// 🔴 房間類型那一組曾經是橫排的 `Row(crossAxisAlignment: stretch)`，而它的
/// 父層是 `SingleChildScrollView`——垂直方向沒有上界，stretch 要一個有界的
/// 高度。結果整個對話框被撐開，可見性與任務板被擠出畫面，而選了哪一個也
/// 看不出來。所以這裡同時釘**四組欄位都在**與**選中看得出來**：少了任何
/// 一邊，畫面都還是壞的。
class _FakeRoomsApi extends RoomsApi {
  _FakeRoomsApi() : super(Dio());

  String? lastKind;
  String? lastVisibility;

  @override
  Future<Room> create({
    required String name,
    String topic = '',
    String? sessionKey,
    String visibility = 'public',
    String style = 'verbose',
    String styleInstructions = '',
    String kind = 'chat',
  }) async {
    lastKind = kind;
    lastVisibility = visibility;
    return Room.fromJson({
      'id': 'r1',
      'name': name,
      'kind': kind,
      'created_at': '2026-09-17T00:00:00+00:00',
    });
  }
}

const _config = AppConfig(
  serverUrl: 'http://test',
  token: 'token',
  themeMode: ThemeModePref.dark,
  preferredName: 'Bernie',
  deviceKey: 'device-key',
);

Future<_FakeRoomsApi> _open(WidgetTester tester) async {
  // 給一個高得下的視窗：測試預設 800x600 比這個對話框的內容還矮，
  // 那時「撐滿」與「正常」一樣高，量不出差別
  tester.view.physicalSize = const Size(1200, 1600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final api = _FakeRoomsApi();
  await tester.pumpWidget(ProviderScope(
    overrides: [
      initialConfigProvider.overrideWithValue(_config),
      roomsApiProvider.overrideWithValue(api),
      // 板清單不是這組測試的題目，給一份空的，畫面就不會去打 Hub
      boardLibraryProvider('active')
          .overrideWith((ref) async => const BoardListResult()),
    ],
    child: MaterialApp(
      theme: buildUepTheme(Brightness.dark),
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showCreateRoomDialog(context),
            child: const Text('開'),
          ),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('開'));
  await tester.pumpAndSettle();
  return api;
}

/// 某個選項現在是不是被選起來的——看它那一列有沒有實心的 radio。
bool _selected(WidgetTester tester, String label) {
  final row = find.ancestor(
      of: find.text(label), matching: find.byType(Row)).first;
  return tester
      .widgetList<Icon>(
          find.descendant(of: row, matching: find.byType(Icon)))
      .any((i) => i.icon == Icons.radio_button_checked);
}

void main() {
  testWidgets('四組欄位同時在畫面上：名稱、topic、可見性、房間類型',
      (tester) async {
    await _open(tester);

    expect(find.text('名稱'), findsOneWidget);
    expect(find.text('主題（給 agent 的上下文）'), findsOneWidget);
    expect(find.text('房間類型'), findsOneWidget);
    // 可見性＝私人對話那個勾。它在房間類型**後面**，被擠出畫面時第一個不見
    expect(find.text('私人對話'), findsOneWidget);
    expect(find.text('一般對話'), findsOneWidget);
    expect(find.text('工作房（ops）'), findsOneWidget);
  });

  testWidgets('對話框只有內容那麼高，不會撐滿視窗', (tester) async {
    await _open(tester);
    // 量的是對話框那塊面板（AlertDialog 自己那顆 render box 是滿版的
    // padding 容器，量它永遠等於視窗高度）
    final panel = find
        .descendant(of: find.byType(AlertDialog), matching: find.byType(Material))
        .first;
    final screen = tester.view.physicalSize / tester.view.devicePixelRatio;
    expect(tester.getSize(panel).height, lessThan(screen.height * 0.9),
        reason: '撐滿代表內容被拉到無界高度，後面的欄位就被擠出去了');
  });

  testWidgets('預設是一般對話，而且看得出來選了哪一個', (tester) async {
    await _open(tester);
    expect(_selected(tester, '一般對話'), isTrue);
    expect(_selected(tester, '工作房（ops）'), isFalse);
  });

  testWidgets('點工作房再送出 → 建出去的是 kind == ops', (tester) async {
    final api = await _open(tester);
    await tester.enterText(find.byType(TextField).first, 'ops-room');
    await tester.tap(find.text('工作房（ops）'));
    await tester.pumpAndSettle();

    expect(_selected(tester, '工作房（ops）'), isTrue);
    expect(_selected(tester, '一般對話'), isFalse);

    await tester.tap(find.text('建立'));
    await tester.pumpAndSettle();
    expect(api.lastKind, 'ops');
  });
}
