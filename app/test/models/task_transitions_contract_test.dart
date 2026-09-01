import 'dart:io';

import 'package:chatroom_app/models/board.dart';
import 'package:flutter_test/flutter_test.dart';

/// 跨語言契約：**App 畫出來的按鈕必須是 Hub 轉移表的子集**。
///
/// Hub 那側 `tests/test_board_gates.py` 十四條閘門測試守得很緊，而四條 App
/// 缺陷還是全部溜了進來——因為漏的整段都在 App 側：沒有任何測試檢查畫面
/// 上那幾顆按鈕跟 Hub 認的轉移是不是同一回事。補幾個個案治不了這個，個案
/// 只會證明個案自己。
///
/// 所以這條測試**直接讀 `app.py` 的 `TASK_TRANSITIONS`**。錨點放在 Hub 那
/// 側是刻意的：Hub 是唯一真相來源，改了它而沒改 App，紅的應該是 App。
///
/// ⚠️ 找不到檔案時**不 skip**。skip 掉的話，這條測試在最需要它的那天
/// （有人動了 Hub 的表）會安靜地不執行，而綠燈看起來一模一樣。
void main() {
  /// 從 repo 根往回找 `server/chatroom_server/app.py`。
  ///
  /// 測試的工作目錄是 `app/`，但別的執行方式（IDE、CI）不保證，所以往上
  /// 找而不是寫死一層。
  File hubSource() {
    var dir = Directory.current;
    for (var i = 0; i < 5; i++) {
      final f = File('${dir.path}/server/chatroom_server/app.py');
      if (f.existsSync()) return f;
      dir = dir.parent;
    }
    fail('找不到 server/chatroom_server/app.py——這條契約測試沒有比對的對象，'
        '不能當作通過。從 ${Directory.current.path} 往上找了五層。');
  }

  /// 解析 Hub 那份 `TASK_TRANSITIONS`。
  Map<String, Set<String>> parseHubTransitions(String source) {
    final block = RegExp(r'TASK_TRANSITIONS\s*=\s*\{(.*?)\n\s*\}', dotAll: true)
        .firstMatch(source);
    if (block == null) {
      fail('app.py 裡找不到 TASK_TRANSITIONS——它被改名或改寫了，'
          'App 這側那份副本現在沒有任何東西擋著它漂移。');
    }
    final body = block.group(1)!;
    final rows = RegExp(r'"(\w+)"\s*:\s*\{([^}]*)\}').allMatches(body);
    return {
      for (final r in rows)
        r.group(1)!: RegExp(r'"(\w+)"')
            .allMatches(r.group(2)!)
            .map((m) => m.group(1)!)
            .toSet(),
    };
  }

  late Map<String, Set<String>> hub;

  setUpAll(() => hub = parseHubTransitions(hubSource().readAsStringSync()));

  test('解析到的表不是空的——解析壞掉不可以長得像通過', () {
    expect(hub, isNotEmpty);
    expect(hub['todo'], isNotNull, reason: 'todo 是起點，它不在就是解析錯了');
  });

  test('🔑 App 的轉移表與 Hub 逐格相同', () {
    expect(kTaskTransitions, hub);
  });

  test('🔑 每個狀態畫出來的按鈕都是 Hub 允許的轉移', () {
    for (final entry in hub.entries) {
      final targets = taskActionsFor(entry.key).map((a) => a.target).toSet();
      expect(targets.difference(entry.value), isEmpty,
          reason: '${entry.key} 出了 Hub 不允許的按鈕——按下去只會拿 409');
    }
  });

  test('🔑 Hub 允許的轉移都畫得出來，沒有到不了的狀態', () {
    // 這一半才是 in_progress 那個缺陷會被抓到的地方。只驗「沒有多的」的話，
    // 一顆按鈕都不出也會通過，而那正是使用者做不完一張卡的原因。
    for (final entry in hub.entries) {
      final targets = taskActionsFor(entry.key).map((a) => a.target).toSet();
      expect(entry.value.difference(targets), isEmpty,
          reason: '${entry.key} 有 Hub 允許、但畫面上按不到的轉移');
    }
  });

  test('board 畫面不得再出現硬編碼的狀態字串', () {
    // 四顆非法按鈕是這麼來的：每顆自己寫死一個目標狀態，於是轉移表在
    // widget 裡被重寫了一遍。狀態只能從 TaskAction.target 來。
    final dir = Directory('${Directory.current.path}/lib/screens/board');
    final literal = RegExp(r"setTaskStatus\([^)]*?'(\w+)'", dotAll: true);
    final offenders = <String>[];
    for (final f in dir.listSync().whereType<File>()) {
      for (final m in literal.allMatches(f.readAsStringSync())) {
        offenders.add('${f.uri.pathSegments.last}: ${m.group(1)}');
      }
    }
    expect(offenders, isEmpty,
        reason: '狀態要從 taskActionsFor() 來，不要在 widget 裡自己寫一份');
  });
}
