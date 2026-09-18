import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/config/build_info.dart';
import '../core/theme/uep_theme.dart';
import '../core/theme/uep_tokens.dart';
import '../state/app_providers.dart';

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
    final appLabel = _appLabel(ref.watch(appBuildProvider));
    final hubLabel = _hubLabel(ref.watch(hubBuildProvider).value);
    final text = different
        ? 'App 與 Hub 不是同一份程式碼（App $appLabel / Hub $hubLabel）'
            '——通常是 App 還沒換新版；請確認兩邊都用同一次建置的產物'
        // unknown 不是「沒事」：至少一邊講不出自己是哪一份，而那正是
        // 「我以為我更新過了」這種誤判的溫床
        : '無法確認 App 與 Hub 是不是同一份程式碼（App $appLabel / '
            'Hub $hubLabel），其中一邊沒有版本資訊';

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
        // 實際的版本字串一定要印出**兩邊**，不能只印自己這一半——「對不上」
        // 這個結論回答不了「哪一邊舊」，而那才是下一步要做什麼的依據
        Flexible(
          child: Text(
            'App $appLabel · Hub $hubLabel',
            textAlign: TextAlign.right,
            maxLines: 2,
            style: UepText.mono(size: 8.5, color: s.inkMute, height: 1.6),
          ),
        ),
      ]),
    );
  }
}

/// commit 截短成看得完的長度，但**不動 `-dirty`**：那個後綴的意思是
/// 「這份產物對不回任何一個 commit」，截掉它等於把最該看見的事藏起來。
String _shortCommit(String commit) {
  final dirty = commit.endsWith('-dirty');
  final hash = dirty ? commit.substring(0, commit.length - '-dirty'.length) : commit;
  final head = hash.length > 7 ? '${hash.substring(0, 7)}…' : hash;
  return dirty ? '$head-dirty' : head;
}

String _appLabel(BuildInfo b) {
  // 講不出自己是哪一份時印「未知」，不拿版本號去填
  return b.isKnown ? '${b.version}+${_shortCommit(b.commit)}' : '未知';
}

String _hubLabel(Map<String, dynamic>? build) {
  final commit = (build?['commit'] as String?) ?? '';
  if (commit.isEmpty) return '未知';
  final version = (build?['version'] as String?) ?? '?';
  return '$version+${_shortCommit(commit)}';
}
