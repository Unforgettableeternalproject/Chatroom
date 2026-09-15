import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/config/build_info.dart';
import '../core/theme/uep_theme.dart';
import '../core/theme/uep_tokens.dart';
import '../state/app_providers.dart';
import 'kind_badge.dart';

/// App 與 Hub 版本對不上時的警示條。
///
/// 位置在畫面最上方而不是設定頁深處：這條訊息要回答的問題是「我現在看到的
/// 東西是不是最新的」，而那個疑問**發生在你發現某個功能不見的那一刻**，
/// 不是在你想起要去翻設定的時候。
///
/// 相符時完全不畫——正常狀態不該佔用任何版面。
class VersionBanner extends ConsumerWidget {
  const VersionBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.uep;
    final match = ref.watch(versionMatchProvider).value;
    if (match == null || match == VersionMatch.same) {
      return const SizedBox.shrink();
    }

    final different = match == VersionMatch.different;
    final color = different ? UepColors.error : UepColors.gold;
    final text = different
        ? 'App 與 Hub 不是同一份程式碼——畫面上的功能可能與伺服器對不起來，'
            '請重新取得最新版本'
        // unknown 不是「沒事」：至少一邊講不出自己是哪一份，而那正是
        // 「我以為我更新過了」這種誤判的溫床
        : '無法確認 App 與 Hub 是不是同一份程式碼（其中一邊沒有版本資訊）';

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .10),
        border: Border(bottom: BorderSide(color: color.withValues(alpha: .5))),
      ),
      child: Row(children: [
        Icon(different ? Icons.warning_amber_rounded : Icons.help_outline,
            size: 15, color: color),
        const SizedBox(width: 9),
        Expanded(
          child: Text(text,
              style: UepText.serif(size: 12, color: s.ink, height: 1.6)),
        ),
        const SizedBox(width: 10),
        // 實際的版本字串一定要印出來，不能只說「對不上」——回報問題的人
        // 需要的是這兩個值，而不是一個結論
        MonoLabel(BuildInfo.current.label, size: 8.5, color: s.inkMute),
      ]),
    );
  }
}
