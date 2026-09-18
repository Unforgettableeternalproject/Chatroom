import 'package:flutter/material.dart';

import '../core/theme/uep_tokens.dart';
import 'kind_badge.dart';

/// 頁內分頁列——底線用 `s.line`，選中的標籤走 gold。
///
/// 設定頁與這台機器頁共用同一顆：兩頁的分頁列各寫一份的話，間距與顏色
/// 會各自漂移，而使用者是把它們當同一個東西在看的。
///
/// 自己聽 `controller`（`AnimatedBuilder`）而不是要求呼叫端 setState——
/// 少一個「呼叫端要記得做」的步驟，選中色就不會停在上一個分頁。
class UepTabBar extends StatelessWidget {
  const UepTabBar({
    super.key,
    required this.controller,
    required this.labels,
  });

  final TabController controller;
  final List<String> labels;

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    return Container(
      decoration:
          BoxDecoration(border: Border(bottom: BorderSide(color: s.line))),
      child: AnimatedBuilder(
        animation: controller,
        builder: (context, _) => TabBar(
          controller: controller,
          indicatorColor: UepColors.gold,
          indicatorSize: TabBarIndicatorSize.tab,
          dividerColor: Colors.transparent,
          splashFactory: NoSplash.splashFactory,
          tabs: [
            for (var i = 0; i < labels.length; i++)
              Tab(
                height: 42,
                child: MonoLabel(
                  labels[i],
                  size: 11,
                  color: controller.index == i ? UepColors.gold : s.inkMute,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
