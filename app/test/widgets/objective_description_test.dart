import 'package:chatroom_app/core/theme/uep_theme.dart';
import 'package:chatroom_app/screens/board/board_objective_description.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import '../helpers/l10n.dart';

/// 週期敘述太長時不可以把抬頭撐高（任務板頂部擠壓階段列表）。
Future<void> _pump(WidgetTester tester, String text) => tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: kTestLocalizationsDelegates,
        supportedLocales: kTestSupportedLocales,
        theme: buildUepTheme(Brightness.dark),
        home: Scaffold(body: Center(child: ObjectiveDescription(text: text))),
      ),
    );

void main() {
  final longText = List.generate(40, (i) => '第 $i 段敘述內容很長很長很長').join('\n');

  testWidgets('長敘述：高度受限、出現展開、點了看得到全文', (tester) async {
    await _pump(tester, longText);

    final textBox = tester.getSize(
        find.byKey(const ValueKey('objective-description-text')));
    // 4 行 × 14 × 1.85 ≈ 104；40 行不截斷會超過 1000
    expect(textBox.height, lessThan(130));
    expect(find.byKey(const ValueKey('objective-description-expand')),
        findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('objective-description-expand')));
    await tester.pumpAndSettle();

    final full = find.byKey(const ValueKey('objective-description-full'));
    expect(full, findsOneWidget);
    expect(tester.widget<SelectableText>(full).data, longText);
  });

  testWidgets('短敘述：沒有展開按鈕', (tester) async {
    await _pump(tester, '一句話的敘述');
    expect(find.byKey(const ValueKey('objective-description-expand')),
        findsNothing);
    expect(find.text('一句話的敘述'), findsOneWidget);
  });
}
