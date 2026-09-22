import 'package:flutter/material.dart';

import '../core/config/app_settings.dart';
import '../core/theme/uep_tokens.dart';

/// 側邊欄與主內容之間的可拖曳分隔線。
///
/// 只回報**位移**（[onDelta]），寬度由誰持有就由誰夾——這支不知道自己旁邊
/// 那一欄的上下限，也不該知道。
///
/// 游標在 [MouseRegion] 上就換成左右箭頭：可拖曳這件事沒有其他提示，
/// 一條 1px 的線看起來與其他分隔線一模一樣。
class PaneDivider extends StatelessWidget {
  const PaneDivider({
    super.key,
    required this.onDelta,
    required this.onReset,
    required this.tooltip,
  });

  /// 這一格拖了多少（往右為正，單位 px）。
  final ValueChanged<double> onDelta;

  /// 雙擊還原成預設寬。
  final VoidCallback onReset;

  final String tooltip;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.resizeLeftRight,
      child: GestureDetector(
        // 透明區域也要吃得到手勢：這條線本身沒有畫任何東西，
        // 靠的是旁邊那欄的邊框
        behavior: HitTestBehavior.opaque,
        onHorizontalDragUpdate: (d) => onDelta(d.delta.dx),
        onDoubleTap: onReset,
        child: Tooltip(
          message: tooltip,
          waitDuration: const Duration(milliseconds: 700),
          child: SizedBox(
            width: kPaneDividerWidth,
            height: double.infinity,
            child: Center(
              child: Container(
                width: 1,
                color: context.uep.hairline,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
