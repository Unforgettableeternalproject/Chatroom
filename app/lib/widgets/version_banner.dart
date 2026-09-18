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
///
/// 🔴 **橫幅上不放 commit hash。** 橫幅要回答的是「我現在該做什麼」，
/// 而 hash 答不了那一題——答得了的是 `built_at`：早的那邊就是舊的那邊。
/// hash 留在 tooltip 與設定頁，回報問題時才需要。
class VersionBanner extends ConsumerWidget {
  const VersionBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.uep;
    final match = ref.watch(versionMatchProvider).value;
    if (match == null || match == VersionMatch.same) {
      return const SizedBox.shrink();
    }

    final app = ref.watch(appBuildProvider);
    final hub = ref.watch(hubBuildProvider).value;
    final older = _olderSide(app, hub);
    final color = older == null ? UepColors.gold : UepColors.error;
    final text = switch (older) {
      _Side.app => 'App 版本較舊，請更新 App',
      _Side.hub => 'Hub 版本較舊，請更新 Hub',
      null => '無法確認版本',
    };

    return Tooltip(
      message: 'App ${_appLabel(app)} · Hub ${_hubLabel(hub)}',
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: color.withValues(alpha: .10),
          border: Border(bottom: BorderSide(color: color.withValues(alpha: .5))),
        ),
        child: Row(children: [
          Icon(older == null ? Icons.help_outline : Icons.warning_amber_rounded,
              size: 15, color: color),
          const SizedBox(width: 9),
          Expanded(
            child: Text(text,
                style: UepText.serif(size: 12, color: s.ink, height: 1.6)),
          ),
        ]),
      ),
    );
  }
}

/// 哪一邊比較舊。**判準是建置時間，不是 hash**——hash 只說得出「不一樣」，
/// 說不出誰要更新。任一邊講不出建置時間（或兩邊同時）就回 null。
_Side? _olderSide(BuildInfo app, Map<String, dynamic>? hubBuild) {
  final appAt = DateTime.tryParse(app.builtAt);
  final hubAt = DateTime.tryParse((hubBuild?['built_at'] as String?) ?? '');
  if (appAt == null || hubAt == null) return null;
  if (appAt.isBefore(hubAt)) return _Side.app;
  if (hubAt.isBefore(appAt)) return _Side.hub;
  return null;
}

enum _Side { app, hub }

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
