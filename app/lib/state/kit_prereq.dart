import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_providers.dart';
import 'host_probe.dart';
import 'kit_installer.dart';

/// 裝一包 kit 之前，這台機器上要先有的東西。
///
/// ## 三包之間沒有相依，相依的是外部環境
///
/// runner-kit 自帶 bridge、hub-kit 自己起服務——**不要**把「先裝 Hub 才能裝
/// 執行器」寫進來，那是一條不存在的規則。真正會讓安裝完的東西不能用的是
/// 外面那些：直譯器、CLI、以及 Hub 現在連不連得到。
///
/// ## 子進程叫不起來＝「找不到」，不是例外
///
/// 🔴 這裡每一個探測都把失敗吞成「沒有」。丟出去的話 Riverpod 會把那個
/// provider 標成 error 並在每次 rebuild 重試，畫面就永遠停在「檢查中」，
/// 而真正的原因（PATH 裡沒有 claude）一個字都不會出現。
enum KitPrereqKind {
  /// Python（判準與安裝器 [KitInstaller.findPython] 同一份）。
  python,

  /// Claude Code CLI **或** Codex CLI，有一個就算過。
  agentCli,

  /// Claude Code CLI（執行器只起得動 claude）。
  claudeCli,

  /// 設定裡那個 Hub 位址現在打不打得到。
  hub,
}

/// 這一項為什麼不過。
enum KitPrereqIssue {
  /// 機器上找不到它。
  missing,

  /// 設定頁還沒填 Hub 位址——沒得打，不是打不通。
  hubUnset,

  /// 位址有，但打不到。
  hubUnreachable,
}

@immutable
class KitPrereq {
  const KitPrereq(this.kind, {this.issue, this.detail = ''});

  final KitPrereqKind kind;

  /// `null` ＝這一項過了。
  final KitPrereqIssue? issue;

  /// 過了的時候拿來講「找到的是哪一個」（直譯器、CLI 名、Hub 位址）；
  /// 不過的時候是那個打不到的位址。
  final String detail;

  bool get ok => issue == null;
}

/// `claude --version` 叫不叫得起來。回版本那一行，叫不起來回 `null`。
final claudeCliProvider =
    FutureProvider<String?>((ref) => _probeCli(ref, 'claude'));

/// `codex --version` 叫不叫得起來。
final codexCliProvider =
    FutureProvider<String?>((ref) => _probeCli(ref, 'codex'));

Future<String?> _probeCli(Ref ref, String executable) async {
  try {
    final r = await ref.watch(kitProcessRunnerProvider).run(
      executable,
      const ['--version'],
    );
    if (r.exitCode != 0) return null;
    final text = '${r.stdout}${r.stderr}'.trim();
    return text.isEmpty ? executable : text.split('\n').first.trim();
  } on Object {
    // 找不到執行檔、逾時、shell 出錯都是同一件事：這台機器上沒有它
    return null;
  }
}

/// 設定裡那個 Hub 現在連不連得到（`/api/health`）。
///
/// 位址沒填時**不打**：`http:///api/health` 必定失敗，而那個失敗指不出
/// 「去設定頁填位址」這件該做的事。
final kitHubReachableProvider = FutureProvider<bool>((ref) async {
  final url = ref.watch(appConfigProvider.select((c) => c.serverUrl)).trim();
  if (url.isEmpty) return false;
  return probeHealth('${_trimSlash(url)}/api/health');
});

String _trimSlash(String url) =>
    url.endsWith('/') ? url.substring(0, url.length - 1) : url;

/// 這一包裝得下去嗎。列出來的每一項都是**必要**的，任何一項 ✕ 就擋安裝。
final kitPrereqsProvider =
    FutureProvider.family<List<KitPrereq>, KitId>((ref, kit) async {
  final python = await ref.watch(kitPythonProvider.future);
  final pythonRow = KitPrereq(
    KitPrereqKind.python,
    issue: python == null ? KitPrereqIssue.missing : null,
    detail: python?.toString() ?? '',
  );
  if (kit == KitId.hub) return [pythonRow];

  final claude = await ref.watch(claudeCliProvider.future);

  Future<KitPrereq> hubRow() async {
    final url =
        ref.read(appConfigProvider.select((c) => c.serverUrl)).trim();
    if (url.isEmpty) {
      return const KitPrereq(KitPrereqKind.hub, issue: KitPrereqIssue.hubUnset);
    }
    final reachable = await ref.watch(kitHubReachableProvider.future);
    return KitPrereq(
      KitPrereqKind.hub,
      issue: reachable ? null : KitPrereqIssue.hubUnreachable,
      detail: url,
    );
  }

  if (kit == KitId.runner) {
    return [
      pythonRow,
      KitPrereq(
        KitPrereqKind.claudeCli,
        issue: claude == null ? KitPrereqIssue.missing : null,
        detail: claude ?? '',
      ),
      await hubRow(),
    ];
  }

  // Agent 接入包：claude 與 codex 有一個就算過——這一包是給 agent 用的
  // 橋，而兩種 agent 都接得上它。
  final codex = claude != null ? null : await ref.watch(codexCliProvider.future);
  return [
    pythonRow,
    KitPrereq(
      KitPrereqKind.agentCli,
      issue: claude == null && codex == null ? KitPrereqIssue.missing : null,
      detail: claude ?? codex ?? '',
    ),
    await hubRow(),
  ];
});

/// 重讀一次：底下那幾個 provider 各自有快取，只 invalidate 家族的那一個
/// 會拿回同一組舊答案。
void recheckKitPrereqs(WidgetRef ref) {
  ref.invalidate(kitPythonProvider);
  ref.invalidate(claudeCliProvider);
  ref.invalidate(codexCliProvider);
  ref.invalidate(kitHubReachableProvider);
  ref.invalidate(kitPrereqsProvider);
}
