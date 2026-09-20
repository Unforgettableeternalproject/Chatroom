import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/theme/uep_theme.dart';
import '../../core/theme/uep_tokens.dart';
import '../../l10n/l10n.dart';
import '../../state/app_providers.dart';
import '../../state/host_actions.dart';
import '../../state/kit_installer.dart';
import '../../widgets/uep_button.dart';
import 'host_directory_picker.dart';
import 'host_value_row.dart';

/// 一包 kit 的「安裝／更新」區塊。
///
/// ## 只有對得上 Release 的 App 才裝得了東西
///
/// 查的是 `releases/tags/v<這份 App 的版本>`。dev build 查不到，那時按鈕
/// **停用並說明白**——不退到 latest：退過去的話，一份沒發布過的 App 會裝上
/// 一包與它不同源的 kit，而出事時沒有人分得出那兩邊差在哪。
///
/// ## 這裡不判斷安裝本身成不成功
///
/// 成敗只看安裝器最後印的那一行 `RESULT`。畫面不去數檔案、不去猜 exit code
/// ——兩份判準會在某次改動後分岔，而分岔的那一刻沒有任何地方報錯。
class KitInstallSection extends ConsumerStatefulWidget {
  const KitInstallSection({
    super.key,
    required this.kit,
    required this.installed,
    this.installedVersion = '',
  });

  final KitId kit;

  /// 這台機器上已經有這一包了嗎（有＝按鈕講「更新」）。
  final bool installed;

  /// 已裝的版本，可能帶 `+commit`；比對時只看 `+` 前面那段。
  final String installedVersion;

  @override
  ConsumerState<KitInstallSection> createState() => _KitInstallSectionState();
}

class _KitInstallSectionState extends ConsumerState<KitInstallSection> {
  /// 解壓到哪。預設就是安裝器原本的固定位置——**同一份**
  /// （`KitInstaller.defaultTargetFor`），畫面上寫的與實際裝的不會分岔。
  ///
  /// 🔴 在 `initState` 就建好，不要 `late`：沒走到安裝那一段的畫面（沒有
  /// Release、少了資產）不會碰到它，於是 `dispose()` 才第一次初始化，
  /// 而那時 `ref` 已經不能用了。
  late final TextEditingController _path;

  /// 位置不能用的理由。按下安裝當下才算，算完擋在解壓之前。
  KitPathProblem? _problem;

  KitId get kit => widget.kit;
  bool get installed => widget.installed;
  String get installedVersion => widget.installedVersion;

  @override
  void initState() {
    super.initState();
    _path = TextEditingController(
        text: ref.read(kitInstallerProvider).defaultTargetFor(widget.kit));
  }

  @override
  void dispose() {
    _path.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    final l10n = AppLocalizations.of(context);
    final release = ref.watch(kitReleaseProvider);
    final state = ref.watch(kitInstallsProvider)[kit] ?? const KitInstallState();

    final rows = <Widget>[];

    if (!installed) {
      rows.add(Text(l10n.hostKitInstallNotInstalled(_kitName(l10n)),
          style: UepText.serif(size: 14, color: s.inkSoft)));
      rows.add(const SizedBox(height: 10));
    }

    final value = release.value;
    if (release.isLoading) {
      rows.add(_note(context, l10n.hostKitInstallChecking));
    } else if (value == null) {
      // 本機來源（dev build）或那一版根本沒發：沒有線上安裝可用，這句話
      // 要講得出「那我該做什麼」——自己打包，而不是一句「請用安裝包」
      rows.add(Text(l10n.hostKitInstallNoRelease(kit.buildScript),
          style: UepText.serif(size: 13.5, color: s.inkSoft)));
    } else {
      rows.addAll(_releaseRows(context, ref, value, state));
    }

    if (state.phase != KitInstallPhase.idle) {
      rows.add(const SizedBox(height: 10));
      rows.add(_statusLine(context, state));
      // 安裝器沒覆寫設定檔時要講出來——不講的話，人會以為剛才那組 Hub
      // 位址與 token 已經生效
      if (state.result?.configKept ?? false) {
        rows.add(const SizedBox(height: 6));
        rows.add(Text(l10n.hostKitInstallConfigKept,
            style: UepText.serif(size: 13, color: UepColors.gold)));
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l10n.hostKitInstallTitle,
            style: UepText.fieldLabel(color: s.inkMute)),
        const SizedBox(height: 12),
        ...rows,
      ],
    );
  }

  List<Widget> _releaseRows(
    BuildContext context,
    WidgetRef ref,
    KitRelease release,
    KitInstallState state,
  ) {
    final l10n = AppLocalizations.of(context);
    final rows = <Widget>[
      _note(context, l10n.hostKitInstallSource(release.tag)),
      const SizedBox(height: 4),
      _note(context, l10n.hostKitInstallTargetVersion(release.version)),
      const SizedBox(height: 12),
    ];

    if (release.assetFor(kit) == null) {
      rows.add(Text(l10n.hostKitInstallAssetMissing(kit.assetName),
          style: UepText.serif(size: 13.5, color: UepColors.error)));
      return rows;
    }

    // 已經是同一版就不必再裝一次——按鈕留著但按不動，理由寫在旁邊
    final upToDate = installed && _sameVersion(installedVersion, release.version);
    final python = ref.watch(kitPythonProvider);
    final missingPython = !python.isLoading && python.value == null;
    final busyRunner =
        kit == KitId.runner && (ref.watch(runnerBusyProvider).value ?? false);

    final blocked = upToDate || missingPython || busyRunner || state.busy;

    rows.add(_pathRow(context, l10n, enabled: !state.busy));
    rows.add(const SizedBox(height: 12));

    rows.add(Row(children: [
      UepButton(
        label: installed ? l10n.hostKitUpdateButton : l10n.hostKitInstallButton,
        small: true,
        onPressed: blocked ? null : () => _start(ref, release),
      ),
      if (upToDate) ...[
        const SizedBox(width: 12),
        Flexible(child: _note(context, l10n.hostKitInstallUpToDate)),
      ],
      if (busyRunner) ...[
        const SizedBox(width: 12),
        Flexible(
          child: Text(l10n.hostKitInstallRunnerBusy,
              style: UepText.serif(size: 13, color: UepColors.gold)),
        ),
      ],
    ]));

    if (missingPython) {
      rows.add(const SizedBox(height: 10));
      rows.add(Text(l10n.hostKitInstallNoPython,
          style: UepText.serif(size: 13.5, color: UepColors.gold)));
      rows.add(const SizedBox(height: 8));
      rows.add(UepButton(
        label: l10n.hostKitInstallPythonLink,
        small: true,
        variant: UepButtonVariant.outline,
        onPressed: () => launchUrl(Uri.parse(kPythonDownloadUrl),
            mode: LaunchMode.externalApplication),
      ));
    }

    rows.add(const SizedBox(height: 10));
    rows.add(_note(
      context,
      kit == KitId.hub && installed
          ? l10n.hostKitInstallHubNote
          : l10n.hostKitInstallUacNote,
    ));

    if (kit == KitId.hub && installed) {
      rows.addAll(_serviceRows(context, ref));
    }
    return rows;
  }

  /// Hub 裝完還差一步：排程工作沒註冊的話，「啟動」按了也不會自己回來。
  List<Widget> _serviceRows(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final service = ref.watch(serviceStatusProvider).value;
    final actions = ref.watch(hostActionsProvider);
    if (actions == null || (service?.registered ?? true)) return const [];
    return [
      const SizedBox(height: 14),
      Row(children: [
        UepButton(
          label: l10n.hostKitRegisterService,
          small: true,
          variant: UepButtonVariant.outline,
          onPressed: () async {
            await actions.service('install');
            ref.invalidate(serviceStatusProvider);
          },
        ),
        const SizedBox(width: 12),
        Flexible(child: _note(context, l10n.hostKitRegisterServiceHint)),
      ]),
    ];
  }

  /// 按下去之後的那一串。
  ///
  /// Hub 的更新要**先停再裝**：覆蓋一個正在跑的 Hub 的檔案，壞的是所有
  /// 連著它的人，而不是按下按鈕的那一個。停完才裝，裝完再起回來。
  Future<void> _start(WidgetRef ref, KitRelease release) async {
    // 🔴 位置不能用的話**連下載都不要開始**：解壓到一半才發現寫不進去，
    // 磁碟上會留下半包東西，而畫面只講得出一句沒有指向的「安裝失敗」。
    final target = _path.text.trim();
    final problem = await checkKitInstallPath(target);
    if (!mounted) return;
    setState(() => _problem = problem);
    if (problem != null) return;

    final config = ref.read(appConfigProvider);
    final extra = <String>[];
    switch (kit) {
      case KitId.hub:
        // 🔴 一律 `--no-tunnel`：預設會去抓 40MB 的 cloudflared，而那是
        // 「要不要讓內網外連進來」這個**另一個決定**的工具。裝 Hub 的人
        // 沒有按過那個決定，不該在他按「安裝」時替他下載。
        extra.add('--no-tunnel');
      case KitId.mcp:
        if (config.serverUrl.isNotEmpty) extra.addAll(['--url', config.serverUrl]);
        if (config.token.isNotEmpty) extra.addAll(['--token', config.token]);
      case KitId.runner:
        if (config.serverUrl.isNotEmpty) {
          extra.addAll(['--hub-url', config.serverUrl]);
        }
        if (config.token.isNotEmpty) extra.addAll(['--token', config.token]);
    }

    final restartHub = kit == KitId.hub && installed;
    final actions = restartHub ? ref.read(hostActionsProvider) : null;
    if (actions != null) await actions.stopHub();

    await ref
        .read(kitInstallsProvider.notifier)
        .install(kit, release: release, targetDir: target, extraArgs: extra);

    if (!restartHub) return;
    final done = (ref.read(kitInstallsProvider)[kit] ?? const KitInstallState())
            .phase ==
        KitInstallPhase.done;
    if (!done) return;
    // 安裝成功才起回來：失敗時那一包可能是半份的，起它只會多一個壞掉的進程
    final after = ref.read(hostActionsProvider);
    if (after != null) await after.service('start');
  }

  Widget _statusLine(BuildContext context, KitInstallState state) {
    final l10n = AppLocalizations.of(context);
    final text = switch (state.phase) {
      KitInstallPhase.checking => l10n.hostKitInstallChecking,
      KitInstallPhase.downloading =>
        l10n.hostKitInstallDownloading('${(state.progress * 100).round()}'),
      KitInstallPhase.extracting => l10n.hostKitInstallExtracting,
      KitInstallPhase.installing => l10n.hostKitInstallRunning,
      KitInstallPhase.done =>
        l10n.hostKitInstallDone(state.result?.version ?? ''),
      KitInstallPhase.failed => _failureText(l10n, state),
      KitInstallPhase.idle => '',
    };
    final color = switch (state.phase) {
      KitInstallPhase.failed => UepColors.error,
      KitInstallPhase.done => UepColors.success,
      _ => context.uep.inkSoft,
    };
    return Text(text, style: UepText.serif(size: 13.5, color: color));
  }

  /// 失敗時講**這一種**失敗，不是一句「安裝失敗」。
  String _failureText(AppLocalizations l10n, KitInstallState state) =>
      switch (state.failure) {
        KitInstallFailure.pythonMissing => l10n.hostKitInstallNoPython,
        KitInstallFailure.assetMissing =>
          l10n.hostKitInstallAssetMissing(kit.assetName),
        _ => l10n.hostKitInstallFailed(state.detail),
      };

  /// 「尚未安裝 X」裡的那個 X。
  String _kitName(AppLocalizations l10n) => switch (kit) {
        KitId.hub => l10n.hostKitNameHub,
        KitId.mcp => l10n.hostKitNameMcp,
        KitId.runner => l10n.hostKitNameRunner,
      };

  /// 安裝位置那一列：欄位（外殼與 Hub 設定那幾列同一個）＋「瀏覽」。
  ///
  /// 填的是**解壓到哪**。host-kit 與 mcp-kit 的 `install.py` 以自己所在的
  /// 位置為 kit 根（原地安裝），runner-kit 另外收 `--dir`——那一層由
  /// `KitInstaller` 補上，這裡只負責問出一個位置。
  Widget _pathRow(BuildContext context, AppLocalizations l10n,
      {required bool enabled}) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: EditRow(
            label: l10n.hostKitInstallPathLabel,
            controller: _path,
            enabled: enabled,
            trailingSlots: 0,
            errorText: _problem == null ? null : _problemText(l10n, _problem!),
            // 改過之後舊的理由就不成立了，留著會讓人以為改了也沒用
            onChanged: (_) {
              if (_problem != null) setState(() => _problem = null);
            },
          ),
        ),
        const SizedBox(width: 12),
        UepButton(
          label: l10n.hostRunnerBrowse,
          small: true,
          variant: UepButtonVariant.outline,
          onPressed: !enabled
              ? null
              : () async {
                  final picked =
                      await pickHostDirectory(l10n.hostKitInstallPathLabel);
                  if (picked == null || !mounted) return;
                  setState(() {
                    _path.text = picked;
                    _problem = null;
                  });
                },
        ),
      ],
    );
  }

  String _problemText(AppLocalizations l10n, KitPathProblem problem) =>
      switch (problem) {
        KitPathProblem.empty => l10n.hostKitInstallPathEmpty,
        KitPathProblem.relative => l10n.hostKitInstallPathRelative,
        KitPathProblem.missingRoot => l10n.hostKitInstallPathMissingRoot,
        KitPathProblem.notWritable => l10n.hostKitInstallPathNotWritable,
      };

  Widget _note(BuildContext context, String text) => Text(
        text,
        style: UepText.code(size: 11.5, color: context.uep.inkMute),
      );

  /// 已裝的版本可能是 `1.2.3+abcdef`，Release 給的是 `1.2.3`。
  static bool _sameVersion(String installed, String release) {
    if (installed.isEmpty || release.isEmpty) return false;
    final at = installed.indexOf('+');
    return (at < 0 ? installed : installed.substring(0, at)) == release;
  }
}
