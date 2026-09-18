import 'package:chatroom_app/core/theme/uep_theme.dart';
import 'package:chatroom_app/screens/rooms/room_list_screen.dart';
import 'package:chatroom_app/state/runner_kit_presence.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';

/// 建房對話框的「工作房」閘。
///
/// 工作房（ops）的用途是給遠端派工，而派工要有一台執行器接。這台機器沒裝
/// runner-kit 時開得出工作房的話，使用者要等到第一次派工、派出去沒有人接
/// 才會發現——**而那時房已經建好了，Hub 沒有「把工作房改回一般房」的端點**。
///
/// 兩邊都要驗：只驗「沒裝時擋住」的話，一個永遠回 false 的偵測也會全綠，
/// 而它會讓裝好執行器的機器也開不了工作房。
Widget _host({required bool hasRunner}) => ProviderScope(
      overrides: [
        runnerKitPresentProvider.overrideWith((ref) async => hasRunner),
      ],
      child: MaterialApp(
        theme: buildUepTheme(Brightness.dark),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showCreateRoomDialog(context),
              child: const Text('建立房間'),
            ),
          ),
        ),
      ),
    );

const _kOpsLabel = '工作房（ops）';
const _kChatLabel = '一般對話';
const _kNote = '這台機器沒裝執行器，開不了工作房';

/// 這個選項現在是被選中的嗎——看它自己那一列的圓鈕。
bool _selected(WidgetTester tester, String label) {
  final row = find.ancestor(of: find.text(label), matching: find.byType(Row));
  final icon = tester.widget<Icon>(
      find.descendant(of: row.first, matching: find.byType(Icon)).first);
  return icon.icon == Icons.radio_button_checked;
}

Future<void> _open(WidgetTester tester, {required bool hasRunner}) async {
  await tester.pumpWidget(_host(hasRunner: hasRunner));
  await tester.tap(find.text('建立房間'));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);

  testWidgets('🔴 沒裝執行器：工作房選不動，而且說得出理由', (tester) async {
    await _open(tester, hasRunner: false);

    expect(find.text(_kNote), findsOneWidget);
    await tester.tap(find.text(_kOpsLabel));
    await tester.pump();

    expect(_selected(tester, _kOpsLabel), isFalse);
    expect(_selected(tester, _kChatLabel), isTrue);
  });

  testWidgets('裝了執行器：工作房照常選得動，也不再多那句話', (tester) async {
    await _open(tester, hasRunner: true);

    expect(find.text(_kNote), findsNothing);
    await tester.tap(find.text(_kOpsLabel));
    await tester.pump();

    expect(_selected(tester, _kOpsLabel), isTrue);
    expect(_selected(tester, _kChatLabel), isFalse);
  });
}
