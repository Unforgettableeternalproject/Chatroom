import 'package:chatroom_app/screens/chat/chat_screen.dart';
import 'package:flutter_test/flutter_test.dart';

/// 🔴 2026-09-09（艾斯維爾 09/09 房 seq 22）：從釘選列表跳到原訊息，
/// 訊息多的房間定位會偏。
///
/// 根因是粗跳用寫死的「96px/則」推落點，訊息一多就差出好幾個螢幕；差到
/// 目標落在 build 範圍外時，第二段精修拿不到 context 而被安靜跳過——
/// **沒有人檢查粗跳有沒有成功**（除錯Novia 09/09 房 seq 45 診斷）。
///
/// 這裡驗的是換掉的那個估計本身。「重跳到量得到為止」與「用完重試要出聲」
/// 兩件事需要真實的 sliver 佈局，留在實機驗收。
void main() {
  test('最新那則不用捲——offset 0', () {
    expect(
      estimateFocusOffset(fromBottom: 0, total: 300, maxExtent: 30000),
      0,
    );
  });

  test('最舊那則捲到底', () {
    expect(
      estimateFocusOffset(fromBottom: 299, total: 300, maxExtent: 30000),
      30000,
    );
  });

  test('中間那則按比例落在中間', () {
    expect(
      estimateFocusOffset(fromBottom: 150, total: 301, maxExtent: 30000),
      15000,
    );
  });

  test('🔴 每則平均高度不是 96px 時也要對——這正是原本會偏的情況', () {
    // 300 則、總高 60000 ⇒ 平均 200px/則（帶圖的訊息很容易到這個量級）。
    // 舊的算法會給 150 * 96 = 14400，實際該在 30000——差了一半的捲軸，
    // 目標當然不在 build 範圍裡
    final offset =
        estimateFocusOffset(fromBottom: 150, total: 301, maxExtent: 60000);
    expect(offset, 30000);
    expect(offset, isNot(150 * 96.0));
  });

  test('不會超出捲動上限', () {
    final offset =
        estimateFocusOffset(fromBottom: 999, total: 300, maxExtent: 30000);
    expect(offset, lessThanOrEqualTo(30000));
  });

  test('還沒佈局（maxExtent 為 0）時回 0，不是 NaN', () {
    expect(estimateFocusOffset(fromBottom: 10, total: 300, maxExtent: 0), 0);
  });

  test('只有一則訊息時不除以零', () {
    expect(estimateFocusOffset(fromBottom: 0, total: 1, maxExtent: 500), 0);
  });
}
