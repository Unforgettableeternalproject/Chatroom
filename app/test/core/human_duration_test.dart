import 'package:chatroom_app/core/util/relative_time.dart';
import 'package:flutter_test/flutter_test.dart';

/// 時長顯示。
///
/// 原本成員列直接印分鐘數，掛了兩天的 agent 會顯示「閒置 3120 分」——
/// 那個數字要讀的人自己去除以 60，而畫面存在的意義就是免去這件事
/// （艾斯維爾 2026-09-11 在想法板提的）。
void main() {
  group('一小時以內維持分鐘', () {
    test('0 分不是空字串', () {
      // 空字串會讓「閒置 」後面什麼都沒有，看起來像壞掉
      expect(humanDuration(Duration.zero), '0 分');
    });

    test('59 分還是分', () {
      expect(humanDuration(const Duration(minutes: 59)), '59 分');
    });
  });

  group('進位到時', () {
    test('整點不顯示 0 分', () {
      expect(humanDuration(const Duration(minutes: 120)), '2 時');
    });

    test('有餘數就兩段', () {
      expect(humanDuration(const Duration(minutes: 125)), '2 時 5 分');
    });

    test('剛好一小時', () {
      expect(humanDuration(const Duration(minutes: 60)), '1 時');
    });

    test('23 小時還沒進位到日', () {
      expect(humanDuration(const Duration(minutes: 23 * 60 + 30)), '23 時 30 分');
    });
  });

  group('進位到日', () {
    test('整日只有一段', () {
      expect(humanDuration(const Duration(days: 1)), '1 日');
    });

    test('日與時', () {
      expect(humanDuration(const Duration(minutes: 25 * 60)), '1 日 1 時');
    });

    test('三段都有', () {
      expect(humanDuration(const Duration(minutes: 25 * 60 + 5)), '1 日 1 時 5 分');
    });

    test('🔴 中間段是 0 時也要保留位置', () {
      // `1 日 5 分` 若省成 `1 日 5 分` 沒問題，但若把「時」整個吃掉寫成
      // `1 日 5`，就會與「1 日 5 時」分不出來。這條守的是**單位不可以省**
      expect(humanDuration(const Duration(minutes: 24 * 60 + 5)), '1 日 5 分');
    });

    test('原始抱怨的那個數字', () {
      // 3120 分 = 2 日 4 時
      expect(humanDuration(const Duration(minutes: 3120)), '2 日 4 時');
    });
  });

  group('邊界', () {
    test('負的時長不顯示負號', () {
      // 倒數算出負值時（時鐘漂移、門檻被改小）顯示「-3 分後移出」很怪
      expect(humanDuration(const Duration(minutes: -3)), '0 分');
    });

    test('不足一分鐘算 0 分，不是空的', () {
      expect(humanDuration(const Duration(seconds: 30)), '0 分');
    });
  });
}
