import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import 'package:windows_taskbar/windows_taskbar.dart';

final _log = Logger('badge');

/// 工作列圖示上的未處理數字（Discord 那個紅點）。
///
/// **存在的理由是持續性，不是顯眼程度。** 右下角的系統通知是會過去的——
/// 看漏一次就沒了，而使用者當下多半正在別的視窗裡。徽章不會自己消失，
/// 它留在那裡直到那件事真的被處理掉。把 toast 做得更花解決不了這個，
/// 因為問題不在「不夠醒目」，在「只出現一瞬間」。
///
/// 數字綁在**未處理**而不是**未讀**上：問題卡片被滑過去但沒答，數字不減。
/// 那正是「容易被忽略」的成因，減掉它等於把這個機制關掉。
class TaskbarBadge {
  TaskbarBadge._();

  static final instance = TaskbarBadge._();

  /// 上次套用的值。Win32 呼叫不便宜，而這個數字每次 feed 變動都會重算。
  int? _applied;

  /// 只有 Windows 有這個東西。其他平台靜默略過——不是失敗，是不適用。
  bool get _supported => !kIsWeb && Platform.isWindows;

  /// [count] 是未處理項目總數；0 表示清掉角標。
  Future<void> apply(int count) async {
    if (!_supported) return;
    final n = count < 0 ? 0 : count;
    if (_applied == n) return;
    _applied = n;
    try {
      if (n == 0) {
        await WindowsTaskbar.resetOverlayIcon();
        return;
      }
      // 10 以上一律 9+：兩位數在 16x16 的角標上讀不出來，而「很多」這個
      // 資訊本身就夠了——確切數字進 App 裡看
      final asset = n > 9 ? 'assets/badge/9plus.ico' : 'assets/badge/$n.ico';
      await WindowsTaskbar.setOverlayIcon(
        ThumbnailToolbarAssetIcon(asset),
        tooltip: '$n 件未處理',
      );
    } catch (e) {
      // 角標失敗不該影響任何功能。但也不要靜靜吞掉——「徽章沒出現」
      // 與「沒有未處理的事」在畫面上長得一模一樣
      _log.warning('工作列角標套用失敗（count=$n）：$e');
      _applied = null; // 下次重試，不要因為記住了而永遠不再嘗試
    }
  }
}
