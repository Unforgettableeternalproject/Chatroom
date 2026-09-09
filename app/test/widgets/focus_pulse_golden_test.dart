@Tags(['golden'])
library;

import 'package:chatroom_app/core/theme/uep_theme.dart';
import 'package:chatroom_app/core/theme/uep_tokens.dart';
import 'package:chatroom_app/models/message.dart';
import 'package:chatroom_app/widgets/message_bubble.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 呼吸光暈框修正的驗收圖（09/09 房 seq 22 的對比用）。
///
/// ⚠️ **它會跟著一般 `flutter test` 跑。** tag 在這個專案裡只是標籤，沒有
/// 任何東西被 `--exclude-tags` 排除（理由見 `dart_test.yaml`：沒有人跑的
/// 測試等於沒有測試）。所以它同時是一道回歸防線——呼吸框再偏掉時這裡會紅。
///
/// 代價是 golden 對字型與平台敏感：換機器、或 `google_fonts` 在測試環境
/// 突然抓得到網路字型時，它會因為與功能無關的原因紅。**那時要重產，不是
/// 去改實作**——先確認 `focus_pulse_alignment_test` 仍然綠（那支量的是
/// 位置，不看畫面），再：
/// `flutter test test/widgets/focus_pulse_golden_test.dart --update-goldens`
void main() {
  Message msg(String content) => Message(
        id: 'm1',
        seq: 1,
        updateSeq: 0,
        kind: 'chat',
        content: content,
        senderName: '決策Novia',
        createdAt: '2026-09-09T00:00:00+00:00',
      );

  testWidgets('跳轉聚焦的光暈框貼合氣泡（自己的／別人的）', (tester) async {
    tester.view.physicalSize = const Size(900, 460);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      theme: buildUepTheme(Brightness.dark),
      home: Builder(
        builder: (context) => Scaffold(
          backgroundColor: context.uep.bg,
          body: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                MessageBubble(
                  message: msg('別人的訊息：光暈框要貼合氣泡，不再往左多出 14px'),
                  isSelf: false,
                  senderKind: 'claude',
                  highlighted: true,
                ),
                const SizedBox(height: 24),
                MessageBubble(
                  message: msg('自己的訊息：本來就準，修正不可以把它弄歪'),
                  isSelf: true,
                  senderKind: 'human',
                  highlighted: true,
                ),
              ],
            ),
          ),
        ),
      ),
    ));
    // 呼吸動畫停在較亮的相位，框才看得清楚
    await tester.pump(const Duration(milliseconds: 550));

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/focus_pulse_after.png'),
    );
  });
}
