import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/errors/api_exception.dart';
import '../../core/theme/uep_theme.dart';
import '../../core/theme/uep_tokens.dart';
import '../../l10n/l10n.dart';
import '../../state/app_providers.dart';
import '../../state/runner_kit_providers.dart';
import '../../state/runs_providers.dart';
import '../../widgets/empty_error_states.dart';
import '../../widgets/reveal.dart';
import '../../widgets/uep_button.dart';

/// 執行器的工作區設定：工作區裡有哪些專案、公開給誰派工、優先載入哪個 skill。
///
/// ## 兩層：工作區 → 專案
///
/// 工作區是外層資料夾（派工時 Hub 認得的那個 key），專案是它底下的 git repo。
/// 畫面照這個層級走：一個工作區一張卡，收合時只剩標題列；展開後專案、skill、
/// 設定各成一塊，靠左側縮排與導引線把「誰屬於誰」畫出來。
///
/// ## 權威在本機的 `config.json`，不在 Hub
///
/// 專案路徑與 skill 目錄本來就是「這台機器的事」——Hub 驗不了它們在這台
/// 機器上存不存在。所以這一頁與 Hub 分頁讀寫 `.env` 是同一個模式：直接讀寫
/// 本機檔案，改完再經 Hub 對**這台**執行器發一個 `reload`，讓它自己重讀。
///
/// `reload` 走既有的 `runner_command`（issued→acked→applied）——改設定不另開
/// 一條 Hub 不認得的平行通路。
class RunnerWorkspacesSection extends ConsumerWidget {
  const RunnerWorkspacesSection({super.key, required this.kit});

  final RunnerKit kit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.uep;
    final l10n = AppLocalizations.of(context);
    final cfg = ref.watch(runnerConfigProvider);

    return cfg.when(
      loading: () => _shell(
        context,
        Text(l10n.commonLoading,
            style: UepText.serif(size: 14, color: s.inkMute)),
      ),
      error: (e, _) => _shell(context, ErrorState(error: e)),
      data: (config) {
        if (config == null) {
          return _shell(
            context,
            Text(l10n.hostRunnerConfigUnreadable(kit.configPath),
                style: UepText.serif(size: 14, color: s.inkMute)),
          );
        }
        return _shell(
          context,
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _DashedCard(
                label: l10n.hostRunnerAddWorkspace,
                onTap: () => _addWorkspace(context, ref, config),
              ),
              if (config.workspaces.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 30),
                  child: EmptyState(title: l10n.hostRunnerNoWorkspaces),
                ),
              for (final w in config.workspaces)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: _RunnerWorkspaceCard(
                      key: ValueKey('ws:${config.path}:${w.key}'),
                      config: config,
                      workspace: w),
                ),
              const SizedBox(height: 16),
              Text(l10n.hostRunnerWorkspacePrivateNote,
                  style: UepText.serif(size: 13, color: s.inkMute)),
            ],
          ),
        );
      },
    );
  }

  /// 區塊標題（與其他設定區同一組 fieldLabel）＋內容。
  Widget _shell(BuildContext context, Widget child) {
    final s = context.uep;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(AppLocalizations.of(context).hostRunnerPanelWorkspaces,
            style: UepText.fieldLabel(color: s.inkMute)),
        const SizedBox(height: 12),
        SizedBox(width: double.infinity, child: child),
      ],
    );
  }

  Future<void> _addWorkspace(
      BuildContext context, WidgetRef ref, RunnerConfigFile config) async {
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final added = await showDialog<bool>(
      context: context,
      builder: (_) => _AddWorkspaceDialog(config: config),
    );
    if (added != true) return;
    final said = await _runnerApplyReload(ref, l10n);
    messenger.showSnackBar(SnackBar(content: Text(said)));
  }
}

/// 存檔之後：重讀設定，並對這台執行器發 `reload`。
///
/// 回傳的是要給使用者看的那一句——**存檔與命令是兩件事**：寫進去了但命令
/// 沒送出（拿不到 runner_id、Hub 連不上）時要講「已存檔，執行器還沒收到」，
/// 而不是一句籠統的成功，那會讓人以為設定已經在跑著的執行器上生效了。
Future<String> _runnerApplyReload(WidgetRef ref, AppLocalizations l10n) async {
  ref.invalidate(runnerConfigProvider);
  final runnerId = await ref.read(runnerIdProvider.future);
  if (runnerId == null) return l10n.hostRunnerSavedNoRunnerId;
  try {
    await ref.read(runsApiProvider).command(
          runnerId,
          command: 'reload',
          sessionKey: ref.read(appConfigProvider).deviceKey,
        );
    return l10n.hostRunnerSavedReloadSent;
  } on ApiException catch (e) {
    return l10n.hostRunnerReloadFailed(e.message);
  }
}

/// 把資料層的例外翻成一句話。衝突（重讀再試）與值不對（改了再存也一樣）
/// 是兩種不同的處置，訊息要分得開。
String _runnerErrorText(Object error, AppLocalizations l10n) {
  if (error is RunnerConfigConflict) return l10n.hostRunnerConflict;
  if (error is RunnerConfigInvalid) return error.message;
  return l10n.hostRunnerWriteFailed('$error');
}

/// 路徑的最後一段，拿來當專案的預設名稱。
String _lastSegment(String path) {
  final parts = path
      .replaceAll('\\', '/')
      .split('/')
      .where((p) => p.isNotEmpty)
      .toList();
  return parts.isEmpty ? '' : parts.last;
}

/// 開系統的資料夾選擇器。取消回 `null`。
Future<String?> _pickDirectory(String title) async {
  try {
    final path = await FilePicker.getDirectoryPath(dialogTitle: title);
    if (path == null || path.trim().isEmpty) return null;
    return path;
  } on Object {
    // 沒有選擇器可用的平台：旁邊的輸入框照樣打得了字
    return null;
  }
}

/// 一個工作區一張卡。收合時只剩標題列。
class _RunnerWorkspaceCard extends ConsumerStatefulWidget {
  const _RunnerWorkspaceCard({
    super.key,
    required this.config,
    required this.workspace,
  });

  final RunnerConfigFile config;
  final RunnerWorkspace workspace;

  @override
  ConsumerState<_RunnerWorkspaceCard> createState() =>
      _RunnerWorkspaceCardState();
}

class _RunnerWorkspaceCardState extends ConsumerState<_RunnerWorkspaceCard> {
  late bool _public = widget.workspace.public;
  late bool _livetest = widget.workspace.allowBrowserLivetest;
  late String _folder = widget.workspace.folder;
  late List<String> _skillDirs = List.of(widget.workspace.skillDirs);
  late String _primarySkill = widget.workspace.primarySkill;
  bool _saving = false;
  bool _expanded = false;
  bool _advancedOpen = false;

  late final _model = TextEditingController(text: widget.workspace.model);
  late final _maxTurns =
      TextEditingController(text: _num(widget.workspace.maxTurns));
  late final _budget =
      TextEditingController(text: _num(widget.workspace.maxBudgetUsd));
  late final _wallClock =
      TextEditingController(text: _num(widget.workspace.wallClockSeconds));
  late final _contextWindow =
      TextEditingController(text: _num(widget.workspace.contextWindowTokens));

  /// 0 ＝ 沒設，欄位就留空（空的意思是「沿用執行器的預設」，不是 0）。
  static String _num(num value) {
    if (value <= 0) return '';
    if (value is int || value == value.roundToDouble()) {
      return value.toInt().toString();
    }
    return value.toString();
  }

  @override
  void dispose() {
    _model.dispose();
    _maxTurns.dispose();
    _budget.dispose();
    _wallClock.dispose();
    _contextWindow.dispose();
    super.dispose();
  }

  int get _maxTurnsValue => int.tryParse(_maxTurns.text.trim()) ?? 0;
  double get _budgetValue => double.tryParse(_budget.text.trim()) ?? 0;
  int get _wallClockValue => int.tryParse(_wallClock.text.trim()) ?? 0;
  int get _contextWindowValue => int.tryParse(_contextWindow.text.trim()) ?? 0;

  bool get _dirty =>
      _public != widget.workspace.public ||
      _livetest != widget.workspace.allowBrowserLivetest ||
      _folder != widget.workspace.folder ||
      _primarySkill != widget.workspace.primarySkill ||
      _model.text.trim() != widget.workspace.model ||
      _maxTurnsValue != widget.workspace.maxTurns ||
      _budgetValue != widget.workspace.maxBudgetUsd ||
      _wallClockValue != widget.workspace.wallClockSeconds ||
      _contextWindowValue != widget.workspace.contextWindowTokens ||
      !_sameList(_skillDirs, widget.workspace.skillDirs);

  static bool _sameList(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// 表單存檔 → 發 `reload`。
  ///
  /// 優先載入 skill 是**另一次寫入**（它要對著 skill_dirs 驗證），所以這裡
  /// 存完要重讀一份設定再寫第二次——拿舊的那份寫會撞上 mtime 檢查。
  Future<void> _save() async {
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _saving = true);
    try {
      await saveRunnerWorkspace(
        widget.config,
        workspaceKey: widget.workspace.key,
        folder: _folder,
        public: _public,
        allowBrowserLivetest: _livetest,
        model: _model.text.trim(),
        maxTurns: _maxTurnsValue,
        maxBudgetUsd: _budgetValue,
        wallClockSeconds: _wallClockValue,
        contextWindowTokens: _contextWindowValue,
        skillDirs: _skillDirs,
      );
      if (_primarySkill != widget.workspace.primarySkill) {
        ref.invalidate(runnerConfigProvider);
        final fresh = await readRunnerConfig(widget.config.path);
        if (fresh == null) throw const RunnerConfigConflict();
        await setRunnerPrimarySkill(
          fresh,
          workspaceKey: widget.workspace.key,
          skill: _primarySkill,
        );
      }
    } on Object catch (e) {
      if (mounted) setState(() => _saving = false);
      ref.invalidate(runnerConfigProvider);
      messenger
          .showSnackBar(SnackBar(content: Text(_runnerErrorText(e, l10n))));
      return;
    }

    final said = await _runnerApplyReload(ref, l10n);
    if (mounted) setState(() => _saving = false);
    messenger.showSnackBar(SnackBar(content: Text(said)));
  }

  /// 立刻寫檔的動作（加／移除專案、設預設、移除工作區）。
  ///
  /// 與表單的「儲存並套用」同一條路：寫完重讀設定、發 `reload`、把結果講出來。
  Future<void> _write(Future<void> Function() action) async {
    final l10n = AppLocalizations.of(context);
    // 移除工作區之後這張卡就不在了；訊息要交給不會跟著消失的 messenger
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _saving = true);
    try {
      await action();
    } on Object catch (e) {
      if (mounted) setState(() => _saving = false);
      ref.invalidate(runnerConfigProvider);
      messenger
          .showSnackBar(SnackBar(content: Text(_runnerErrorText(e, l10n))));
      return;
    }
    final said = await _runnerApplyReload(ref, l10n);
    if (mounted) setState(() => _saving = false);
    messenger.showSnackBar(SnackBar(content: Text(said)));
  }

  Future<void> _addSkillDir() async {
    final path = await showDialog<String>(
      context: context,
      builder: (context) => _PathDialog(
        title: AppLocalizations.of(context).hostRunnerAddSkillDirTitle,
        label: AppLocalizations.of(context).hostRunnerSkillDirHint,
      ),
    );
    if (path == null || path.isEmpty) return;
    if (_skillDirs.contains(path)) return;
    setState(() => _skillDirs = [..._skillDirs, path]);
  }

  Future<void> _pickFolder() async {
    final l10n = AppLocalizations.of(context);
    final path = await _pickDirectory(l10n.hostRunnerFolder);
    if (path == null) return;
    setState(() => _folder = path);
  }

  Future<void> _addProject() async {
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final added = await showDialog<bool>(
      context: context,
      builder: (_) => _AddProjectDialog(
        config: widget.config,
        workspaceKey: widget.workspace.key,
      ),
    );
    if (added != true) return;
    final said = await _runnerApplyReload(ref, l10n);
    messenger.showSnackBar(SnackBar(content: Text(said)));
  }

  Future<void> _removeWorkspace() async {
    final l10n = AppLocalizations.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        content:
            Text(l10n.hostRunnerRemoveWorkspaceConfirm(widget.workspace.key)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.commonCancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.commonRemove),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await _write(
        () => removeRunnerWorkspace(widget.config, key: widget.workspace.key));
  }

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    final l10n = AppLocalizations.of(context);

    return Container(
      decoration:
          BoxDecoration(color: s.bgCard, border: Border.all(color: s.hairline)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _header(s, l10n),
          UepExpand(
            expanded: _expanded,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(height: 1, color: s.hairline),
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 16, 14, 14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _block(s, l10n.hostRunnerProjects,
                          _projects(s, l10n, widget.workspace)),
                      _block(s, l10n.hostRunnerSkillDirs, _skills(s, l10n)),
                      _block(s, l10n.settingsTitle, _settings(s, l10n)),
                      Align(
                        alignment: Alignment.centerRight,
                        child: UepButton(
                          label: l10n.hostRunnerSaveApply,
                          small: true,
                          onPressed: (_saving || !_dirty) ? null : _save,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 標題列：工作區 key、資料夾、狀態 chip、展開箭頭、溢位選單。
  Widget _header(UepSurface s, AppLocalizations l10n) {
    return InkWell(
      onTap: () => setState(() => _expanded = !_expanded),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 11, 4, 11),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(widget.workspace.key,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: UepText.sans(
                          size: 15,
                          weight: FontWeight.w600,
                          color: s.inkTitle,
                          height: 1.3)),
                  const SizedBox(height: 3),
                  Text(
                    _folder.isEmpty ? l10n.hostRunnerNone : _folder,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: UepText.code(size: 11.5, color: s.inkMute),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            _StatusChip(
              label: _public
                  ? l10n.hostRunnerChipPublic
                  : l10n.hostRunnerChipPrivate,
              on: _public,
            ),
            if (_livetest) ...[
              const SizedBox(width: 6),
              _StatusChip(label: l10n.hostRunnerChipLivetest, on: true),
            ],
            const SizedBox(width: 2),
            IconButton(
              tooltip: _expanded ? l10n.commonCollapse : l10n.commonExpand,
              onPressed: () => setState(() => _expanded = !_expanded),
              icon: AnimatedRotation(
                turns: _expanded ? .5 : 0,
                duration: kUepRevealDuration,
                child: Icon(Icons.keyboard_arrow_down,
                    size: 20, color: s.inkMute),
              ),
            ),
            PopupMenuButton<String>(
              icon: Icon(Icons.more_horiz, size: 18, color: s.inkMute),
              enabled: !_saving,
              onSelected: (_) => _removeWorkspace(),
              itemBuilder: (context) => [
                PopupMenuItem(
                  value: 'remove',
                  child: Text(l10n.hostRunnerRemoveWorkspace,
                      style: UepText.serif(size: 13.5, color: s.ink)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 展開內容的一塊：小標＋左側縮排與導引線，把層級畫出來。
  Widget _block(UepSurface s, String label, Widget child) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: UepText.fieldLabel(color: s.inkMute)),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.only(left: 5),
            child: Container(
              padding: const EdgeInsets.only(left: 14),
              decoration: BoxDecoration(
                border: Border(left: BorderSide(color: s.hairlineStrong)),
              ),
              child: child,
            ),
          ),
        ],
      ),
    );
  }

  /// 工作區裡的專案：一個專案一張子卡，末尾是虛線框的「加專案」。
  Widget _projects(UepSurface s, AppLocalizations l10n, RunnerWorkspace w) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final e in w.projects.entries)
          _projectCard(s, l10n, w, e.key, e.value),
        _DashedCard(
          label: l10n.hostRunnerAddProject,
          dense: true,
          onTap: _saving ? null : _addProject,
        ),
      ],
    );
  }

  Widget _projectCard(UepSurface s, AppLocalizations l10n, RunnerWorkspace w,
      String name, RunnerProject project) {
    final isDefault = name == w.defaultProject;
    final rules = <String>[
      if (project.allowedBranches.isNotEmpty)
        l10n.hostRunnerBranchesAllowed(
            project.allowedBranches.join(l10n.commonListSeparator)),
      if (project.pushBranches.isNotEmpty)
        l10n.hostRunnerBranchesPush(
            project.pushBranches.join(l10n.commonListSeparator)),
    ];
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
      decoration:
          BoxDecoration(color: s.bgSoft, border: Border.all(color: s.hairline)),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: UepText.sans(
                              size: 13.5,
                              weight: FontWeight.w600,
                              color: s.ink,
                              height: 1.3)),
                    ),
                    if (isDefault) ...[
                      const SizedBox(width: 6),
                      _StatusChip(label: l10n.hostRunnerDefaultTag, on: true),
                    ],
                  ],
                ),
                const SizedBox(height: 3),
                Text(project.path,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: UepText.code(size: 11.5, color: s.inkMute)),
                if (rules.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(rules.join('　'),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: UepText.serif(
                          size: 12, color: s.inkMute, height: 1.5)),
                ],
              ],
            ),
          ),
          if (!isDefault)
            TextButton(
              onPressed: _saving
                  ? null
                  : () => _write(() => saveRunnerWorkspace(
                        widget.config,
                        workspaceKey: w.key,
                        defaultProject: name,
                      )),
              child: Text(l10n.hostRunnerSetDefaultProject,
                  style: UepText.serif(size: 12.5, color: s.inkMute)),
            ),
          IconButton(
            tooltip: l10n.commonRemove,
            icon: Icon(Icons.close, size: 16, color: s.inkMute),
            onPressed: _saving
                ? null
                : () => _write(() => removeRunnerProject(
                      widget.config,
                      workspaceKey: w.key,
                      name: name,
                    )),
          ),
        ],
      ),
    );
  }

  /// skill 目錄（chip 列，可刪可加）＋優先載入 skill。
  Widget _skills(UepSurface s, AppLocalizations l10n) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            for (final dir in _skillDirs)
              _PathChip(
                path: dir,
                onRemove: _saving
                    ? null
                    : () => setState(
                        () => _skillDirs = [..._skillDirs]..remove(dir)),
              ),
            _DashedChip(
              label: l10n.hostRunnerAddDir,
              onTap: _saving ? null : _addSkillDir,
            ),
          ],
        ),
        const SizedBox(height: 12),
        _primarySkillField(s, l10n),
      ],
    );
  }

  /// 優先載入 skill：選項來自這個工作區 `skill_dirs` 底下掃到的 skill。
  ///
  /// 目前選著的那個即使掃不到也要留在清單裡——不然它會在畫面上無聲消失，
  /// 而檔案裡還寫著它。
  Widget _primarySkillField(UepSurface s, AppLocalizations l10n) {
    return FutureBuilder<List<String>>(
      future: listRunnerSkills(_skillDirs),
      builder: (context, snap) {
        final names = <String>{...(snap.data ?? const <String>[])};
        if (_primarySkill.isNotEmpty) names.add(_primarySkill);
        final items = names.toList()..sort();
        return Row(
          children: [
            SizedBox(
              width: 140,
              child: Text(l10n.hostRunnerPrimarySkill,
                  style: UepText.fieldLabel(color: s.inkMute)),
            ),
            Expanded(
              child: DropdownButton<String>(
                value: _primarySkill,
                isExpanded: true,
                underline: const SizedBox.shrink(),
                style: UepText.serif(size: 14, color: s.ink),
                dropdownColor: s.bgSoft,
                items: [
                  DropdownMenuItem(
                    value: '',
                    child: Text(l10n.hostRunnerPrimarySkillNone,
                        style: UepText.serif(size: 14, color: s.inkMute)),
                  ),
                  for (final name in items)
                    DropdownMenuItem(
                      value: name,
                      child: Text(name,
                          style: UepText.serif(size: 14, color: s.ink)),
                    ),
                ],
                onChanged: _saving
                    ? null
                    : (v) => setState(() => _primarySkill = v ?? ''),
              ),
            ),
          ],
        );
      },
    );
  }

  /// 兩個開關＋再收一層的「進階」。
  Widget _settings(UepSurface s, AppLocalizations l10n) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _switchRow(s, l10n.hostRunnerPublic, _public,
            (v) => setState(() => _public = v)),
        _switchRow(s, l10n.hostRunnerLivetest, _livetest,
            (v) => setState(() => _livetest = v)),
        SizedBox(
          height: _kSettingRowHeight,
          child: Row(
            children: [
              Expanded(
                child: SelectableText(
                  _folder.isEmpty ? l10n.hostRunnerNone : _folder,
                  maxLines: 1,
                  style: UepText.code(size: 11.5, color: s.inkSoft),
                ),
              ),
              const SizedBox(width: 12),
              UepButton(
                label: l10n.hostRunnerBrowse,
                small: true,
                variant: UepButtonVariant.outline,
                onPressed: _saving ? null : _pickFolder,
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        InkWell(
          onTap: () => setState(() => _advancedOpen = !_advancedOpen),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              children: [
                Text(l10n.hostRunnerAdvanced,
                    style: UepText.fieldLabel(color: s.inkMute)),
                const SizedBox(width: 4),
                AnimatedRotation(
                  turns: _advancedOpen ? .5 : 0,
                  duration: kUepRevealDuration,
                  child: Icon(Icons.keyboard_arrow_down,
                      size: 18, color: s.inkMute),
                ),
              ],
            ),
          ),
        ),
        UepExpand(
          expanded: _advancedOpen,
          child: Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Column(
              children: [
                _field(s, l10n.hostRunnerModel, _model),
                _field(s, l10n.hostRunnerMaxTurns, _maxTurns, numeric: true),
                _field(s, l10n.hostRunnerMaxBudget, _budget, numeric: true),
                _field(s, l10n.hostRunnerWallClock, _wallClock, numeric: true),
                _field(s, l10n.hostRunnerContextWindow, _contextWindow,
                    numeric: true),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// 開關列。字級、金色與排法照設定頁那兩顆（`settings_screen` 的視覺分頁）；
  /// 這裡多一個 `shrinkWrap`——設定頁一頁只放兩三顆，卡片裡一連三列，
  /// Material 預設的點擊區會把這一塊撐成別的東西。
  Widget _switchRow(
      UepSurface s, String label, bool value, ValueChanged<bool> onChanged) {
    return SizedBox(
      height: _kSettingRowHeight,
      child: Row(
        children: [
          Expanded(
            child: Text(label,
                style: UepText.sans(size: 13.5, color: s.inkTitle)),
          ),
          Switch(
            value: value,
            activeThumbColor: UepColors.gold,
            activeTrackColor: UepColors.gold.withValues(alpha: .28),
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            onChanged: _saving ? null : onChanged,
          ),
        ],
      ),
    );
  }

  Widget _field(UepSurface s, String label, TextEditingController controller,
      {bool numeric = false}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          SizedBox(
            width: 140,
            child: Text(label, style: UepText.fieldLabel(color: s.inkMute)),
          ),
          Expanded(
            child: TextField(
              controller: controller,
              enabled: !_saving,
              keyboardType: numeric ? TextInputType.number : null,
              style: UepText.code(size: 12.5, color: s.ink),
              decoration: InputDecoration(
                isDense: true,
                hintText:
                    AppLocalizations.of(context).hostRunnerFieldDefaultHint,
                hintStyle: UepText.serif(size: 12.5, color: s.inkMute),
              ),
              onChanged: (_) => setState(() {}),
            ),
          ),
        ],
      ),
    );
  }
}

/// 設定區三列（兩個開關、資料夾）的列高，對齊同一條線。
const double _kSettingRowHeight = 36;

/// 標題列上的狀態 chip。開著＝金線，關著＝灰線。
class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.label, required this.on});

  final String label;
  final bool on;

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        border: Border.all(
            color: on ? UepColors.gold.withValues(alpha: .4) : s.hairline),
      ),
      child: Text(
        label,
        style: UepText.mono(
            size: 10,
            color: on ? UepColors.gold : s.inkMute,
            letterSpacing: 1.2),
      ),
    );
  }
}

/// 一個 skill 目錄一顆 chip，右邊是刪。
class _PathChip extends StatelessWidget {
  const _PathChip({required this.path, this.onRemove});

  final String path;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 4, 4, 4),
      decoration:
          BoxDecoration(color: s.bgSoft, border: Border.all(color: s.hairline)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 窄視窗上路徑要讓得出位置：Flexible 收、maxWidth 擋住過長的那幾條
          Flexible(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 260),
              child: Text(path,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: UepText.code(size: 11.5, color: s.inkSoft)),
            ),
          ),
          const SizedBox(width: 2),
          IconButton(
            tooltip: AppLocalizations.of(context).commonRemove,
            constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
            padding: EdgeInsets.zero,
            visualDensity: VisualDensity.compact,
            icon: Icon(Icons.close, size: 14, color: s.inkMute),
            onPressed: onRemove,
          ),
        ],
      ),
    );
  }
}

/// 虛線框的「加一個」chip。
class _DashedChip extends StatelessWidget {
  const _DashedChip({required this.label, this.onTap});

  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    return InkWell(
      onTap: onTap,
      child: CustomPaint(
        painter: _DashedBorderPainter(color: s.hairlineStrong),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.add, size: 13, color: s.inkMute),
              const SizedBox(width: 5),
              Text(label,
                  style: UepText.mono(
                      size: 10.5, color: s.inkMute, letterSpacing: 1.2)),
            ],
          ),
        ),
      ),
    );
  }
}

/// 虛線框的「加一張卡」。它站在自己要加的那一層上，所以是卡不是按鈕列。
class _DashedCard extends StatelessWidget {
  const _DashedCard({required this.label, this.onTap, this.dense = false});

  final String label;
  final VoidCallback? onTap;

  /// 子層（專案）用的矮一點的版本。
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    return InkWell(
      onTap: onTap,
      child: CustomPaint(
        painter: _DashedBorderPainter(color: s.hairlineStrong),
        child: SizedBox(
          width: double.infinity,
          height: dense ? 42 : 52,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.add, size: dense ? 14 : 16, color: s.inkMute),
              const SizedBox(width: 6),
              Text(label,
                  style: UepText.mono(
                      size: dense ? 10.5 : 11.5,
                      color: s.inkMute,
                      letterSpacing: 1.4)),
            ],
          ),
        ),
      ),
    );
  }
}

/// 虛線邊框。Flutter 的 `Border` 只有實線，而「還沒有的東西」要畫成虛線
/// 才不會跟既有的卡搶同一種存在感。
class _DashedBorderPainter extends CustomPainter {
  const _DashedBorderPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = (Offset.zero & size).deflate(.5);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    for (final metric in (Path()..addRect(rect)).computeMetrics()) {
      var start = 0.0;
      while (start < metric.length) {
        final end = (start + 5).clamp(0.0, metric.length);
        canvas.drawPath(metric.extractPath(start, end), paint);
        start = end + 4;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DashedBorderPainter old) => old.color != color;
}

/// 打一個路徑，或按「瀏覽」從系統選一個。
///
/// 兩種都留著：沒有選擇器的平台照樣打得了字，而貼路徑常常比一層層點快。
class _PathDialog extends StatefulWidget {
  const _PathDialog({required this.title, required this.label});

  final String title;
  final String label;

  @override
  State<_PathDialog> createState() => _PathDialogState();
}

class _PathDialogState extends State<_PathDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(widget.title),
      content: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _controller,
              autofocus: true,
              decoration: InputDecoration(hintText: widget.label),
              onSubmitted: (v) => Navigator.of(context).pop(v.trim()),
            ),
          ),
          const SizedBox(width: 8),
          TextButton(
            onPressed: () async {
              final path = await _pickDirectory(widget.title);
              if (path == null || !mounted) return;
              setState(() => _controller.text = path);
            },
            child: Text(l10n.hostRunnerBrowse),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.commonCancel),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(_controller.text.trim()),
          child: Text(l10n.commonAdd),
        ),
      ],
    );
  }
}

/// 新增工作區：名稱、資料夾，資料夾不是 git repo 時還要一個專案路徑。
///
/// 驗證交給資料層（同一條規則只留一份），錯誤**留在對話框裡**顯示——關掉
/// 再從頭填一次是這種表單最討人厭的一件事。
class _AddWorkspaceDialog extends StatefulWidget {
  const _AddWorkspaceDialog({required this.config});

  final RunnerConfigFile config;

  @override
  State<_AddWorkspaceDialog> createState() => _AddWorkspaceDialogState();
}

class _AddWorkspaceDialogState extends State<_AddWorkspaceDialog> {
  final _key = TextEditingController();
  final _folder = TextEditingController();
  final _project = TextEditingController();
  String _error = '';
  bool _busy = false;

  @override
  void dispose() {
    _key.dispose();
    _folder.dispose();
    _project.dispose();
    super.dispose();
  }

  bool get _ready =>
      !_busy && _key.text.trim().isNotEmpty && _folder.text.trim().isNotEmpty;

  Future<void> _submit() async {
    final l10n = AppLocalizations.of(context);
    setState(() {
      _busy = true;
      _error = '';
    });
    try {
      await addRunnerWorkspace(
        widget.config,
        key: _key.text.trim(),
        folder: _folder.text.trim(),
        projectPath: _project.text.trim(),
      );
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = _runnerErrorText(e, l10n);
      });
      return;
    }
    if (mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(l10n.hostRunnerAddWorkspace),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _key,
              autofocus: true,
              enabled: !_busy,
              decoration:
                  InputDecoration(labelText: l10n.hostRunnerWorkspaceKey),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 10),
            _pathRow(l10n, _folder, l10n.hostRunnerFolder, ''),
            const SizedBox(height: 10),
            _pathRow(l10n, _project, l10n.hostRunnerFirstProjectPath,
                l10n.hostRunnerFirstProjectHint),
            if (_error.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(_error,
                  style: UepText.serif(size: 13, color: UepColors.error)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(false),
          child: Text(l10n.commonCancel),
        ),
        TextButton(
          onPressed: _ready ? _submit : null,
          child: Text(l10n.commonAdd),
        ),
      ],
    );
  }

  Widget _pathRow(AppLocalizations l10n, TextEditingController controller,
      String label, String hint) {
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: controller,
            enabled: !_busy,
            decoration: InputDecoration(
              labelText: label,
              hintText: hint.isEmpty ? null : hint,
            ),
            onChanged: (_) => setState(() {}),
          ),
        ),
        const SizedBox(width: 8),
        TextButton(
          onPressed: _busy
              ? null
              : () async {
                  final path = await _pickDirectory(label);
                  if (path == null || !mounted) return;
                  setState(() => controller.text = path);
                },
          child: Text(l10n.hostRunnerBrowse),
        ),
      ],
    );
  }
}

/// 在工作區裡加一個專案。名稱留空就用路徑的最後一段。
class _AddProjectDialog extends StatefulWidget {
  const _AddProjectDialog({required this.config, required this.workspaceKey});

  final RunnerConfigFile config;
  final String workspaceKey;

  @override
  State<_AddProjectDialog> createState() => _AddProjectDialogState();
}

class _AddProjectDialogState extends State<_AddProjectDialog> {
  final _name = TextEditingController();
  final _path = TextEditingController();
  String _error = '';
  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    _path.dispose();
    super.dispose();
  }

  bool get _ready => !_busy && _path.text.trim().isNotEmpty;

  Future<void> _submit() async {
    final l10n = AppLocalizations.of(context);
    final path = _path.text.trim();
    final name =
        _name.text.trim().isEmpty ? _lastSegment(path) : _name.text.trim();
    setState(() {
      _busy = true;
      _error = '';
    });
    try {
      await addRunnerProject(
        widget.config,
        workspaceKey: widget.workspaceKey,
        name: name,
        path: path,
      );
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = _runnerErrorText(e, l10n);
      });
      return;
    }
    if (mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(l10n.hostRunnerAddProject),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _name,
              enabled: !_busy,
              decoration:
                  InputDecoration(labelText: l10n.hostRunnerProjectName),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _path,
                    autofocus: true,
                    enabled: !_busy,
                    decoration:
                        InputDecoration(labelText: l10n.hostRunnerProjectPath),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: _busy
                      ? null
                      : () async {
                          final path =
                              await _pickDirectory(l10n.hostRunnerProjectPath);
                          if (path == null || !mounted) return;
                          setState(() => _path.text = path);
                        },
                  child: Text(l10n.hostRunnerBrowse),
                ),
              ],
            ),
            if (_error.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(_error,
                  style: UepText.serif(size: 13, color: UepColors.error)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(false),
          child: Text(l10n.commonCancel),
        ),
        TextButton(
          onPressed: _ready ? _submit : null,
          child: Text(l10n.commonAdd),
        ),
      ],
    );
  }
}
