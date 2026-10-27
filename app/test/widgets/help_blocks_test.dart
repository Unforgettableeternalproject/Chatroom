import 'package:chatroom_app/core/config/app_settings.dart';
import 'package:chatroom_app/core/theme/uep_theme.dart';
import 'package:chatroom_app/widgets/help_blocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 說明頁的視覺區塊：窄寬度收單欄、表格不溢出、每一檔字級都不溢出。
///
/// 溢出（RenderFlex overflow）會以例外丟出，所以每個案例最後
/// `tester.takeException()` 必須是 null。

Widget _host(Widget child,
        {required double width,
        FontScalePref pref = FontScalePref.medium,
        Brightness brightness = Brightness.dark}) =>
    MaterialApp(
      theme: buildUepTheme(brightness),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(fontScaleFactor(pref))),
        child: child!,
      ),
      home: Scaffold(
        body: SingleChildScrollView(
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(width: width, child: child),
          ),
        ),
      ),
    );

void _view(WidgetTester tester) {
  tester.view.physicalSize = const Size(1600, 4000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

const _cards = [
  HelpCardData(
      tag: 'CHAT',
      title: '聊天室',
      subtitle: '人與 agent 同一間房',
      body: '用 `@名字` 提及成員、`#[標題]` 指涉任務卡；釘選、匯出、封存都在這裡。'),
  HelpCardData(
      tag: 'BOARD',
      title: '任務板',
      subtitle: '週期 → 階段 → 任務',
      body: '一塊板可掛在多間房。階段全部收尾後送審、確認，再決定要不要上板。'),
  HelpCardData(
      tag: 'OPS',
      title: '派工',
      subtitle: '執行器在你的機器上跑 agent',
      body: '選模板、選專案、寫簡述。結果回到房裡，推送與上板由人類按。'),
];

const _headers = ['操作', '怎麼做', '效果'];
const _rows = [
  [
    '跨階段或跨週期搬卡',
    '在卡上按住約 0.3 秒再拖，放到同週期其他開著的階段，或左欄某個進行中的週期',
    '卡搬到目標處',
  ],
  ['提及一群人', '`@agents` `@humans` `@all`', '送出時展開成當下在房裡的實名'],
];

void main() {
  group('parseHelpMarkup', () {
    test('反引號變 code、雙星號變粗體，其餘是純文字', () {
      final chunks = parseHelpMarkup('按 `Enter` 送出，**注意** 換行');
      expect(chunks.map((c) => c.text), ['按 ', 'Enter', ' 送出，', '注意', ' 換行']);
      expect(chunks[1].isCode, isTrue);
      expect(chunks[3].isBold, isTrue);
      expect(chunks[0].isCode || chunks[0].isBold, isFalse);
    });

    test('沒有標記時整段是一個純文字 chunk', () {
      final chunks = parseHelpMarkup('就是一句話');
      expect(chunks, hasLength(1));
      expect(chunks.single.text, '就是一句話');
    });
  });

  group('HelpCardGrid', () {
    test('欄數依換算寬度決定，不超過卡片數', () {
      expect(HelpCardGrid.columnsFor(700, 3), 3);
      expect(HelpCardGrid.columnsFor(500, 3), 2);
      expect(HelpCardGrid.columnsFor(300, 3), 1);
      expect(HelpCardGrid.columnsFor(900, 2), 2);
      expect(HelpCardGrid.columnsFor(900, 1), 1);
    });

    testWidgets('寬時三張並排（同一列），窄時改單欄（上下排）', (tester) async {
      _view(tester);
      await tester
          .pumpWidget(_host(const HelpCardGrid(cards: _cards), width: 720));
      final wideTops = [
        for (final t in ['聊天室', '任務板', '派工']) tester.getTopLeft(find.text(t)).dy,
      ];
      expect(wideTops.toSet(), hasLength(1), reason: '寬時三張卡標題應在同一水平線');

      await tester
          .pumpWidget(_host(const HelpCardGrid(cards: _cards), width: 340));
      final narrowTops = [
        for (final t in ['聊天室', '任務板', '派工']) tester.getTopLeft(find.text(t)).dy,
      ];
      expect(narrowTops[0], lessThan(narrowTops[1]));
      expect(narrowTops[1], lessThan(narrowTops[2]));
      expect(tester.takeException(), isNull);
    });
  });

  group('HelpTable', () {
    testWidgets('寬時是真的表格（Table），窄時收成逐列小卡', (tester) async {
      _view(tester);
      await tester.pumpWidget(_host(
          const HelpTable(headers: _headers, rows: _rows),
          width: 720));
      expect(find.byType(Table), findsOneWidget);

      await tester.pumpWidget(_host(
          const HelpTable(headers: _headers, rows: _rows),
          width: 340));
      expect(find.byType(Table), findsNothing);
      // 窄版每列的第二、三欄前面各帶一個表頭
      expect(find.text('怎麼做'), findsNWidgets(_rows.length));
      expect(tester.takeException(), isNull);
    });
  });

  group('每一檔字級、窄寬與亮暗主題都不溢出', () {
    for (final pref in FontScalePref.values) {
      for (final width in [320.0, 560.0, 720.0]) {
        for (final brightness in Brightness.values) {
          testWidgets('${pref.name} / $width / ${brightness.name}',
              (tester) async {
            _view(tester);
            await tester.pumpWidget(_host(
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: const [
                  HelpSectionBlock(
                    title: '任務板',
                    label: 'BOARD',
                    icon: Icons.dashboard_outlined,
                    intro: '結構是週期 → 階段 → 任務。所有階段收尾後才能送審。',
                    children: [
                      HelpCardGrid(cards: _cards),
                      HelpTable(headers: _headers, rows: _rows),
                      HelpCallout(
                        text: '凍結的週期、唯讀的板，以及目前狀態不能搬動的卡，都拖不動。',
                        tone: HelpCalloutTone.warn,
                        title: '注意',
                      ),
                      HelpCallout(text: '窄視窗左欄會收起。', title: '提示'),
                      HelpSteps(steps: [
                        HelpStepData(
                            title: '選模板', body: '調查、實作一張票、做完整個階段，三選一。'),
                        HelpStepData(title: '寫簡述', body: '最多 2000 字。'),
                        HelpStepData(title: '送出'),
                      ]),
                    ],
                  ),
                ],
              ),
              width: width,
              pref: pref,
              brightness: brightness,
            ));
            expect(tester.takeException(), isNull);
          });
        }
      }
    }
  });

  testWidgets('步驟依序編號', (tester) async {
    _view(tester);
    await tester.pumpWidget(_host(
        const HelpSteps(steps: [
          HelpStepData(title: '甲'),
          HelpStepData(title: '乙', body: '說明'),
        ]),
        width: 400));
    expect(find.text('1'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
    expect(find.text('說明'), findsOneWidget);
  });
}
