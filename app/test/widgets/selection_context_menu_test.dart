import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 訊息區的 `SelectionArea` 必須壓掉原生的選取選單。
///
/// 病灶：`SelectionArea` 在桌面端自帶一份 context menu（Select all／Copy），
/// 而訊息氣泡自己有右鍵選單（釘選／回覆／複製內容／刪除）。右鍵時**兩個浮層
/// 同時出現、互相疊壓**，使用者按不到自己要的那一個。
///
/// ---
///
/// **這是形狀守衛，不是行為測試**，理由照 `docs/FAILURE-PATTERNS.md`：
/// 要用行為測試驗它，得把整個 ChatScreen 連同 provider 樹建起來、再模擬桌面
/// 端的右鍵手勢並斷言浮層數量——而 ChatScreen 沒有 widget 測試基礎。構造不
/// 出那個窗口就不要寫行為測試，**寫了會得到一顆永遠綠的燈**。
///
/// 形狀守衛守的是形狀不是效果，所以要寫明拆除條件：
///
/// > **什麼時候可以拿掉這條**：ChatScreen 有了 widget 測試基礎（能建起
/// > provider 樹並模擬 `onSecondaryTapUp`）之後，改寫成「右鍵只出現一個
/// > 浮層」的行為測試，那時這條就該刪掉——它守的東西會被更準的東西取代。
void main() {
  test('訊息區的 SelectionArea 必須帶 contextMenuBuilder', () {
    final source = File('lib/screens/chat/chat_screen.dart')
        .readAsStringSync();
    final idx = source.indexOf('SelectionArea(');
    expect(idx, isNot(-1),
        reason: '找不到 SelectionArea——它被移除或改名的話這條守衛就失效了，'
            '請確認跨訊息選取還在，然後更新這個測試');

    // 只看它自己那幾行：contextMenuBuilder 必須緊跟在建構子後面
    final window = source.substring(idx, idx + 600);
    expect(window, contains('contextMenuBuilder'),
        reason: '訊息區的 SelectionArea 沒有壓掉原生選取選單。右鍵時它會與'
            '訊息氣泡自己的選單同時彈出、互相疊壓。'
            '修法：contextMenuBuilder 回傳空 widget——'
            '**不要拿掉 SelectionArea**，拖選的能力要留著。');
  });

  test('設定畫面與邀請碼的 SelectableText 不受影響', () {
    // 反向守衛：那兩處**沒有**自訂右鍵選單與之競爭，原生選單是唯一的入口，
    // 而且正是使用者要的（複製版本號、複製邀請碼）。順手把它們一起壓掉的話
    // 會讓那兩個地方變成不能複製，而那不會有任何測試紅。
    for (final path in const [
      'lib/screens/settings/settings_screen.dart',
      'lib/widgets/invite_manager.dart',
    ]) {
      final source = File(path).readAsStringSync();
      expect(source, contains('SelectableText'),
          reason: '$path 的 SelectableText 不見了——那兩處的原生選單是要的');
      expect(source, isNot(contains('contextMenuBuilder')),
          reason: '$path 不該壓掉原生選單：那裡沒有競爭的自訂選單，'
              '壓掉等於讓使用者無法複製，而且不會有任何測試紅');
    }
  });

  group('訊息選單要貼著游標（F16）', () {
    late String source;

    setUp(() {
      source = File('lib/widgets/message_bubble.dart').readAsStringSync();
    });

    test('rootOverlay 與 useRootNavigator 必須成對出現', () {
      // `globalPos` 是全視窗座標，而 showMenu 的 position 相對於它落腳的
      // Overlay。兩端不同時指定 root 就會固定偏離游標一段距離——**偏移量
      // 剛好是兩個 overlay 的原點差**，所以它在某些畫面結構下完全正常，
      // 在另一些畫面上差半個螢幕。那種「大部分時候對」最難查。
      expect(source, contains('rootOverlay: true'),
          reason: '選單的錨點容器要用 root overlay');
      expect(source, contains('useRootNavigator: true'),
          reason: 'showMenu 也要落在 root，否則與上面那個容器不是同一個座標系');
    });

    test('位置用 fromRect 交給 Flutter 算，不自己減四邊', () {
      // 自己算 `overlay.width - dx` 那型在數學上等價，但它把「點在哪」與
      // 「容器多大」揉在一起——容器取錯時錯誤是靜默的，而且邊緣翻轉
      // （右緣溢出自動往內收）不一定生效。
      expect(source, contains('RelativeRect.fromRect'),
          reason: '用 fromRect(點, Offset.zero & overlay.size)');
    });
  });
}
