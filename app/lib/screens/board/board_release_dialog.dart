import 'package:flutter/material.dart';

import '../../core/errors/api_exception.dart';
import '../../core/theme/uep_theme.dart';
import '../../core/theme/uep_tokens.dart';
import '../../l10n/l10n.dart';
import '../../models/release.dart';
import '../../state/board_providers.dart';
import '../../widgets/uep_button.dart';

/// 確認週期，順便上板（C6）。
///
/// ## 為什麼確認要先問一次 Hub
///
/// 「這個週期改過哪些 repo」只有 Hub 算得出來（run 的 git 欄位），「那個
/// repo 的穩定分支是什麼」只有線上的執行器知道。所以對話框一開就打一次
/// `release/candidates`：**`possible` 為 false 就完全不顯示上板那一段**——
/// 畫一個必定被 Hub 擋下來的開關，只是讓人多按一次。
///
/// ## 候選拿不到不擋確認
///
/// 確認週期本來就不需要上板。候選失敗時上面寫一句為什麼，確認照樣按得下去
/// （送出的 body 不帶 `release`）。
///
/// ## verify 與 release 是同一筆請求
///
/// 兩件事要嘛一起成立要嘛都不發生（Hub 端同一交易）。分兩次送的話，會出現
/// 「已確認但沒上板」而畫面上看不出缺了哪一步。
Future<void> showObjectiveVerifyDialog(
  BuildContext context, {
  required BoardActions actions,
  required String objectiveId,
}) =>
    showDialog<void>(
      context: context,
      builder: (_) =>
          _VerifyDialog(actions: actions, objectiveId: objectiveId),
    );

class _VerifyDialog extends StatefulWidget {
  const _VerifyDialog({required this.actions, required this.objectiveId});

  final BoardActions actions;
  final String objectiveId;

  @override
  State<_VerifyDialog> createState() => _VerifyDialogState();
}

class _VerifyDialogState extends State<_VerifyDialog> {
  ReleaseCandidates? _candidates;
  bool _loading = true;

  /// 候選拿不到的那一筆。**存例外不存字串**：要講哪句話得看 `code`，而
  /// 文字跟著語言走——在 `setState` 裡就把話定下來的話，切語言之後它不會變。
  ApiException? _loadFailure;
  bool _busy = false;
  String? _error;

  /// 上板總開關。預設關——確認週期是常態，上板是額外決定。
  bool _release = false;

  /// repo 名 → 有沒有勾。
  final _picked = <String, bool>{};

  /// repo 名 → 來源分支欄。
  final _sources = <String, TextEditingController>{};

  final _tag = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in _sources.values) {
      c.dispose();
    }
    _tag.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final got = await widget.actions.releaseCandidates(widget.objectiveId);
      if (!mounted) return;
      setState(() {
        _candidates = got;
        _loading = false;
        for (final repo in got?.repos ?? const <ReleaseRepoCandidate>[]) {
          // 預設納入有穩定分支的那些；沒設的不可勾
          _picked[repo.name] = repo.eligible;
          _sources[repo.name] =
              TextEditingController(text: repo.defaultSource);
        }
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadFailure = e;
      });
    }
  }

  /// 候選失敗那一行要說的話。
  ///
  /// **「房間已封存」不是這裡該講的事**：候選打的是板背後那間工作房，房沒
  /// 封存、或根本沒綁工作區時 Hub 回的都是它自己那套話。原樣轉述的話，看的
  /// 人會去找一個他根本沒封存過的房間。這兩種都收斂成同一句——對他而言
  /// 下一步是一樣的：把板掛到綁了工作區的房上。
  String _loadErrorText(AppLocalizations l10n, ApiException e) =>
      (e is RoomArchivedException || e.code == 'workspace_not_bound')
          ? l10n.boardReleaseNoWorkspaceRoom
          : e.message;

  List<ReleaseRepoCandidate> get _repos => _candidates?.repos ?? const [];

  /// 上板區塊該不該出現：Hub 說可以，而且真的有候選。
  bool get _releasable => (_candidates?.possible ?? false) && _repos.isNotEmpty;

  /// `possible` 為 false 時，要不要多講一句「換個地方按」。
  ///
  /// 只有 `board_axis`（從板分頁進來）與 `not_ops_room_member`（人不在那間
  /// 工作房）值得講：這兩種**換個地方按就成立**。其餘（例如
  /// `workspace_not_bound`）維持完全不畫上板區——講了也沒有當場做得到的
  /// 下一步。
  bool get _showOpsRoomHint {
    final c = _candidates;
    if (c == null || c.possible) return false;
    return c.reason == 'board_axis' || c.reason == 'not_ops_room_member';
  }

  ReleaseRequest? _request() {
    if (!_release || !_releasable) return null;
    final picked = <ReleaseRepoSelection>[];
    for (final repo in _repos) {
      if (!repo.eligible || _picked[repo.name] != true) continue;
      final source = _sources[repo.name]?.text.trim() ?? '';
      if (source.isEmpty) continue;
      picked.add(
          ReleaseRepoSelection(name: repo.name, sourceBranch: source));
    }
    return picked.isEmpty ? null : ReleaseRequest(repos: picked, tag: _tag.text.trim());
  }

  Future<void> _submit() async {
    if (_busy) return;
    final l10n = AppLocalizations.of(context);
    final release = _request();
    // 開了上板卻一個都沒勾（或分支空著）＝這一步的意思講不出來，先問清楚
    if (_release && _releasable && release == null) {
      setState(() => _error = l10n.boardReleaseNoRepo);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.actions
          .verifyObjective(widget.objectiveId, release: release);
      if (mounted) Navigator.of(context).pop();
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = _messageFor(e);
      });
    }
  }

  /// 上板那幾個碼要講得出「現在怎麼了」。其餘一律用 Hub 的原話——
  /// 它知道為什麼被拒絕，我們只知道被拒絕了。
  String _messageFor(ApiException e) {
    final l10n = AppLocalizations.of(context);
    return switch (e.code) {
      'objective_not_verified' => l10n.boardReleaseNotVerified,
      'release_in_progress' => l10n.boardReleaseInProgress,
      'release_repo_not_eligible' => l10n.boardReleaseRepoNotEligible,
      'release_requires_ops_room' => l10n.boardReleaseOpsRoomOnly,
      _ => e.message,
    };
  }

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    final l10n = AppLocalizations.of(context);
    return AlertDialog(
      backgroundColor: s.bgCard,
      title: Text(l10n.boardVerifyTitle,
          style: UepText.sectionTitle(color: s.inkTitle)),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l10n.boardVerifyExplain,
                  style:
                      UepText.serif(size: 13, color: s.inkMute, height: 1.55)),
              if (_loading) ...[
                const SizedBox(height: 12),
                Text(l10n.commonLoading,
                    style: UepText.serif(size: 13, color: s.inkMute)),
              ],
              if (_loadFailure != null) ...[
                const SizedBox(height: 12),
                Text(l10n.boardReleaseCandidatesFailed(
                        _loadErrorText(l10n, _loadFailure!)),
                    style:
                        UepText.serif(size: 13, color: s.inkMute, height: 1.5)),
              ],
              if (_showOpsRoomHint) ...[
                const SizedBox(height: 12),
                Text(l10n.boardReleaseOpsRoomOnly,
                    style:
                        UepText.serif(size: 13, color: s.inkMute, height: 1.5)),
              ],
              if (_releasable) ...[
                const SizedBox(height: 6),
                Row(
                  children: [
                    Expanded(
                      child: Text(l10n.boardReleaseToggle,
                          style:
                              UepText.sans(size: 13.5, color: s.inkTitle)),
                    ),
                    Switch(
                      value: _release,
                      activeThumbColor: UepColors.gold,
                      activeTrackColor:
                          UepColors.gold.withValues(alpha: .28),
                      materialTapTargetSize:
                          MaterialTapTargetSize.shrinkWrap,
                      onChanged: _busy
                          ? null
                          : (v) => setState(() => _release = v),
                    ),
                  ],
                ),
                if (_release) ..._releaseBody(s, l10n),
              ],
              if (_error != null) ...[
                const SizedBox(height: 10),
                Text(_error!,
                    style: UepText.sans(
                        size: 13, color: UepColors.error, height: 1.45)),
              ],
            ],
          ),
        ),
      ),
      actions: [
        UepButton(
          label: l10n.commonCancel,
          variant: UepButtonVariant.outline,
          small: true,
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
        ),
        UepButton(
          label: l10n.boardObjectiveVerify,
          small: true,
          onPressed: (_busy || _loading) ? null : _submit,
        ),
      ],
    );
  }

  List<Widget> _releaseBody(UepSurface s, AppLocalizations l10n) {
    final settings = _candidates?.settings ?? const ReleaseSettings();
    return [
      const SizedBox(height: 4),
      Text(
          l10n.boardReleaseMergeMethod(
              _mergeMethodLabel(l10n, settings.mergeMethod)),
          style: UepText.serif(size: 12.5, color: s.inkMute)),
      const SizedBox(height: 8),
      for (final repo in _repos) _repoRow(s, l10n, repo),
      const SizedBox(height: 8),
      TextField(
        controller: _tag,
        enabled: !_busy,
        style: UepText.sans(size: 14, color: s.ink),
        decoration: InputDecoration(
          isDense: true,
          border: const OutlineInputBorder(),
          labelText: l10n.boardReleaseTag,
          hintText: l10n.boardReleaseTagHint,
          hintStyle: UepText.sans(size: 13.5, color: s.inkMute),
        ),
      ),
    ];
  }

  /// 一個候選 repo：勾選、穩定分支、commit 數、來源分支。
  ///
  /// 沒設穩定分支的**留在清單裡但不可勾**：把它整個藏起來的話，人會以為
  /// 那個 repo 沒被改過，而真正要做的事（去執行器設定補穩定分支）沒有任何
  /// 線索。
  Widget _repoRow(
      UepSurface s, AppLocalizations l10n, ReleaseRepoCandidate repo) {
    final source = _sources[repo.name];
    final on = repo.eligible && _picked[repo.name] == true;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
      decoration:
          BoxDecoration(color: s.bgSoft, border: Border.all(color: s.hairline)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Checkbox(
                value: on,
                activeColor: UepColors.gold,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                onChanged: (_busy || !repo.eligible)
                    ? null
                    : (v) => setState(() => _picked[repo.name] = v ?? false),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(repo.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: UepText.sans(
                        size: 13.5, weight: FontWeight.w600, color: s.ink)),
              ),
              Text(l10n.boardReleaseCommits(repo.commits),
                  style: UepText.mono(size: 11, color: s.inkMute)),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            repo.stableBranch.isNotEmpty
                ? l10n.boardReleaseStableLabel(repo.stableBranch)
                : l10n.boardReleaseNoStable,
            style: UepText.serif(
                size: 12,
                color: repo.eligible ? s.inkMute : UepColors.error,
                height: 1.5),
          ),
          // 設了穩定分支但本機與 origin 都沒有：執行器會以
          // release_stable_missing 收掉，這裡先不給勾
          if (repo.stableBranch.isNotEmpty && !repo.stableBranchExists) ...[
            const SizedBox(height: 2),
            Text(l10n.boardReleaseStableMissing,
                style: UepText.serif(
                    size: 12, color: UepColors.error, height: 1.5)),
          ],
          if (repo.eligible && source != null) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: source,
                    enabled: !_busy && on,
                    style: UepText.sans(size: 13.5, color: s.ink),
                    decoration: InputDecoration(
                      isDense: true,
                      border: const OutlineInputBorder(),
                      labelText: l10n.boardReleaseSourceLabel,
                    ),
                  ),
                ),
                // 下拉只是把候選填進欄位——分支可以自填（Hub 認得的分支不見得
                // 在這份候選裡）
                if (repo.branches.isNotEmpty)
                  PopupMenuButton<String>(
                    enabled: !_busy && on,
                    icon: Icon(Icons.keyboard_arrow_down,
                        size: 20, color: s.inkMute),
                    onSelected: (v) => setState(() => source.text = v),
                    itemBuilder: (_) => [
                      for (final b in repo.branches)
                        PopupMenuItem(
                          value: b,
                          child: Text(b,
                              style:
                                  UepText.serif(size: 13.5, color: s.ink)),
                        ),
                    ],
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  /// 合併方式的顯示名。這裡**唯讀**：要改它的地方在執行器分頁的工作區卡。
  String _mergeMethodLabel(AppLocalizations l10n, String method) =>
      switch (method) {
        'merge' => l10n.hostRunnerMergeMerge,
        'squash' => l10n.hostRunnerMergeSquash,
        'ff_only' => l10n.hostRunnerMergeFfOnly,
        _ => method,
      };
}
