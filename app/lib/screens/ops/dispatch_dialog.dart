import 'package:flutter/material.dart';
import 'package:logging/logging.dart';

import '../../core/theme/uep_theme.dart';
import '../../core/theme/uep_tokens.dart';
import '../../l10n/l10n.dart';
import '../../models/agent_run.dart';
import '../../widgets/uep_button.dart';

/// 派工對話框填完之後的東西。
///
/// **對話框自己不送出**：送出要房內身分與錯誤轉譯，而那些東西讓這個畫面
/// 測不起來。它只負責「選模板、選專案、寫簡述」這件事本身。
@immutable
class DispatchRequest {
  const DispatchRequest({
    required this.kind,
    required this.project,
    required this.brief,
    this.priority = 0,
  });

  final String kind;
  final String project;
  final String brief;
  final int priority;
}

/// 這個畫面的 log。
///
/// **沒送出的那一次也要留下一行**：09/17 兩次實機派工都是「第一次沒反應、
/// 第二次才送出」，而 App 的 log 對第一次一個字都沒有——「按了沒作用」與
/// 「根本沒按到」在事後長得一模一樣。
final _log = Logger('dispatch');

/// 專案清單的載入結果。
///
/// **失敗不用例外表達**：這個 Future 在對話框掛上監聽之前就可能完成，未被
/// 監聽的錯誤會變成 unhandled async error，而畫面上什麼都不會發生——正是
/// 這次要修掉的那種沉默。
@immutable
class DispatchProjects {
  const DispatchProjects({this.projects = const [], this.error});

  /// 執行器宣告、而且現在還在線的 project key。
  final List<String> projects;

  /// 撈不到清單時要對人講的那句話；null 代表撈成功（清單可能仍是空的）。
  final String? error;
}

/// 對一個階段或一張卡派工（REMOTE-OPS-PLAN §6.2）。
///
/// 人類**不寫自由 prompt**：選模板 + 選目標 + 一段簡述（≤2000）。目標是
/// 呼叫端給的（抽屜裡的那張卡、那個階段），這裡不讓人改——能改的話它就
/// 變成了「派工到任何地方」，而那正是模板化要擋掉的事。
///
/// 專案清單是 **Future**：撈清單要打一趟 Hub，而先撈完再開對話框的話，這段
/// 等待期間畫面上沒有任何東西在動，人只會再按一次。
Future<DispatchRequest?> showDispatchDialog(
  BuildContext context, {
  required String targetLabel,
  required Future<DispatchProjects> projects,
  String? workspaceKey,
}) =>
    showDialog<DispatchRequest>(
      context: context,
      builder: (context) => DispatchDialog(
          targetLabel: targetLabel,
          projects: projects,
          workspaceKey: workspaceKey),
    );

class DispatchDialog extends StatefulWidget {
  const DispatchDialog({
    super.key,
    required this.targetLabel,
    required this.projects,
    this.workspaceKey,
  });

  /// 要派給誰做的那個東西，寫在對話框頂上。派工是**對一個目標**做的，
  /// 而選完模板之後最容易忘的正是自己在哪張卡上按的。
  final String targetLabel;

  /// 可選的專案。
  ///
  /// **來自執行器宣告的 `projects`**（儀表板），不是 App 寫死的清單：Hub
  /// 建單時用同一份資料判 `project_not_served`，兩邊各寫一份的話，畫面上
  /// 選得到的專案會被 Hub 退，而使用者看不出自己選錯了什麼。
  final Future<DispatchProjects> projects;

  /// 這間房綁定的工作區 key。非 null ＝專案**不給選**：Hub 對別的 key 一律
  /// 409 `workspace_project_mismatch`，選得到而送不出去比不給選更糟。
  final String? workspaceKey;

  /// 專案鎖死了沒。
  bool get isLocked => (workspaceKey ?? '').isNotEmpty;

  @override
  State<DispatchDialog> createState() => _DispatchDialogState();
}

class _DispatchDialogState extends State<DispatchDialog> {
  final _brief = TextEditingController();
  late String _kind = kRunTemplates.first.kind;
  String? _project;
  int _priority = 0;
  String? _error;

  /// 清單還沒回來時是 null——**「還沒撈到」與「撈到空的」不是同一件事**：
  /// 前者要等，後者要去看那台機器。
  List<String>? _projects;
  String? _loadError;

  bool get _loading => _projects == null && _loadError == null;

  @override
  void initState() {
    super.initState();
    // 計數要跟著字走
    _brief.addListener(() => setState(() {}));
    // 綁定的房間沒有選擇：專案就是那個 key，從一開始就填好
    if (widget.isLocked) _project = widget.workspaceKey;
    widget.projects.then(_onProjects).catchError((Object e) {
      // Future 說好不會失敗，真的失敗也不能讓畫面停在「載入中」
      _onProjects(DispatchProjects(
          error: L10n.current.opsDispatchProjectsLoadFailed('$e')));
    });
  }

  void _onProjects(DispatchProjects result) {
    if (!mounted) return;
    setState(() {
      _loadError = result.error;
      _projects = result.error == null ? result.projects : const [];
      // 只有一個專案就直接選它——為一個沒有選擇的選擇按一次沒有意義。
      // 多個時仍然不預設：選錯專案會被 Hub 以 `project_not_served` 退，
      // 而那時人已經走開了
      if (_projects!.length == 1) _project = _projects!.first;
    });
    _log.info('派工對話框收到專案清單（目標：${widget.targetLabel}）：'
        '${result.error ?? (result.projects.isEmpty ? '（空）' : result.projects.join('、'))}');
  }

  @override
  void dispose() {
    _brief.dispose();
    super.dispose();
  }

  /// 擋下來就要說出為什麼。
  ///
  /// **每一條不送出的路徑都要留下畫面上的字與一行 log**：停用的按鈕按下去
  /// 什麼都不會發生，而使用者看到的與「這個功能壞了」沒有差別。
  void _reject(String reason) {
    setState(() => _error = reason);
    _log.warning('派工沒有送出（目標：${widget.targetLabel}）：$reason');
  }

  void _submit() {
    final l10n = AppLocalizations.of(context);
    // 鎖定時不看清單：專案由房間決定，撈不撈得到清單都不影響送得出去
    if (widget.isLocked) {
      _submitWith(widget.workspaceKey!);
      return;
    }
    if (_loading) {
      _reject(l10n.opsDispatchStillLoading);
      return;
    }
    if (_loadError != null) {
      _reject(_loadError!);
      return;
    }
    if (_projects!.isEmpty) {
      _reject(l10n.opsDispatchNoProjects);
      return;
    }
    final project = _project;
    if (project == null || project.isEmpty) {
      _reject(l10n.opsDispatchPickProject);
      return;
    }
    _submitWith(project);
  }

  void _submitWith(String project) {
    final l10n = AppLocalizations.of(context);
    final brief = _brief.text.trim();
    // Hub 也擋（`max_length=2000`），這裡先擋是為了不要讓人打完 2500 字
    // 才在送出時被退回來
    if (brief.length > kRunBriefMaxLength) {
      _reject(l10n.opsDispatchBriefTooLong(kRunBriefMaxLength));
      return;
    }
    _log.info('派工送出（目標：${widget.targetLabel}）：'
        'kind=$_kind project=$project priority=$_priority '
        'brief=${brief.length} 字');
    Navigator.of(context).pop(DispatchRequest(
        kind: _kind, project: project, brief: brief, priority: _priority));
  }

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    final l10n = AppLocalizations.of(context);
    final projects = _projects ?? const <String>[];
    return AlertDialog(
      title: Text(l10n.opsDispatchTitle,
          style: UepText.pageTitle(color: s.inkTitle)),
      content: SizedBox(
        width: 460,
        // 錯誤訊息**不放在捲動區裡**：它接在表單最後面的話，人在對話框上半
        // 部按下送出時那行字就在看不到的地方，而畫面看起來完全沒有反應
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Flexible(
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
            Align(
              alignment: Alignment.centerLeft,
              child: Text(l10n.opsDispatchTarget(widget.targetLabel),
                  style: UepText.serif(
                      size: 13.5, color: s.inkSoft, height: 1.5)),
            ),
            const SizedBox(height: 14),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(l10n.opsDispatchTemplate,
                  style: UepText.fieldLabel(color: s.inkSoft)),
            ),
            const SizedBox(height: 7),
            // 每個模板都附一句說明。**選項的名字講不完它會做什麼**——
            // 「調查」與「實作一張票」的差別是會不會動到檔案，那件事不能
            // 靠人自己猜
            for (final t in kRunTemplates)
              InkWell(
                onTap: () => setState(() => _kind = t.kind),
                child: Container(
                  width: double.infinity,
                  margin: const EdgeInsets.only(bottom: 6),
                  padding: const EdgeInsets.all(9),
                  decoration: BoxDecoration(
                    color: _kind == t.kind ? s.bgSunken : null,
                    border: Border.all(
                        color: _kind == t.kind ? UepColors.gold : s.line),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(t.label,
                          style: UepText.sans(
                              size: 13.5,
                              weight: _kind == t.kind
                                  ? FontWeight.w600
                                  : FontWeight.w400,
                              color: s.ink)),
                      const SizedBox(height: 3),
                      Text(t.summary,
                          style: UepText.serif(
                              size: 12, color: s.inkMute, height: 1.4)),
                    ],
                  ),
                ),
              ),
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(l10n.opsDispatchProject,
                  style: UepText.fieldLabel(color: s.inkSoft)),
            ),
            const SizedBox(height: 7),
            if (widget.isLocked)
              // 唯讀列。**不是停用的下拉**：停用的下拉看起來還是一個選擇，
              // 而這裡根本沒有第二個選項
              Align(
                alignment: Alignment.centerLeft,
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Text(widget.workspaceKey!,
                      style: UepText.mono(size: 11.5, color: s.ink)),
                  const SizedBox(width: 8),
                  Text(l10n.opsDispatchProjectLocked,
                      style: UepText.serif(size: 12, color: s.inkMute)),
                ]),
              )
            else if (_loading)
              // 等待要看得見。不然這一格看起來就只是「沒有專案」
              Align(
                alignment: Alignment.centerLeft,
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(
                          strokeWidth: 1.6, color: s.inkMute)),
                  const SizedBox(width: 8),
                  Text(l10n.opsDispatchProjectsLoading,
                      style: UepText.serif(size: 12.5, color: s.inkSoft)),
                ]),
              )
            else if (_loadError != null)
              Align(
                alignment: Alignment.centerLeft,
                child: Text(_loadError!,
                    style: UepText.serif(
                        size: 12.5, color: UepColors.errorText, height: 1.5)),
              )
            else if (projects.isEmpty)
              // 擋下來要說出理由，而且理由要能導向下一步——這一條的下一步在
              // 那台機器上，不在這個畫面裡
              Align(
                alignment: Alignment.centerLeft,
                child: Text(l10n.opsDispatchNoDeclaredProjects,
                    style: UepText.serif(
                        size: 12.5, color: UepColors.errorText, height: 1.5)),
              )
            else
              Align(
                alignment: Alignment.centerLeft,
                child: DropdownButton<String>(
                  value: _project,
                  hint: Text(l10n.opsDispatchSelectProjectHint,
                      style: UepText.sans(size: 13.5, color: s.inkMute)),
                  items: [
                    for (final p in projects)
                      DropdownMenuItem(
                        value: p,
                        child: Text(p,
                            style: UepText.mono(size: 11.5, color: s.ink)),
                      ),
                  ],
                  onChanged: (v) => setState(() => _project = v),
                ),
              ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(l10n.opsDispatchBriefLabel,
                  style: UepText.fieldLabel(color: s.inkSoft)),
            ),
            const SizedBox(height: 7),
            TextField(
              controller: _brief,
              maxLines: 5,
              style: UepText.sans(size: 13.5, color: s.ink),
              decoration: InputDecoration(
                isDense: true,
                border: const OutlineInputBorder(),
                hintText: l10n.opsDispatchBriefHint,
                hintStyle: UepText.serif(size: 13, color: s.inkMute),
              ),
            ),
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerRight,
              child: Text('${_brief.text.trim().length} / $kRunBriefMaxLength',
                  style: UepText.mono(
                      size: 10.5,
                      color: _brief.text.trim().length > kRunBriefMaxLength
                          ? UepColors.error
                          : s.inkMute)),
            ),
            const SizedBox(height: 10),
            Row(children: [
              Text(l10n.opsDispatchPriorityLabel,
                  style: UepText.fieldLabel(color: s.inkSoft)),
              const SizedBox(width: 10),
              // 佇列是 priority DESC + position ASC。數字大的先做
              DropdownButton<int>(
                value: _priority,
                items: [
                  for (final p in [0, 1, 2, 3])
                    DropdownMenuItem(
                      value: p,
                      child: Text(
                          p == 0
                              ? l10n.opsPriorityNormal
                              : l10n.opsPriorityJump(p),
                          style: UepText.sans(size: 13.5, color: s.ink)),
                    ),
                ],
                onChanged: (v) => setState(() => _priority = v ?? 0),
              ),
            ]),
          ]),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(_error!,
                  style: UepText.serif(
                      size: 13.5, color: UepColors.errorText, height: 1.5)),
            ),
          ],
        ]),
      ),
      actions: [
        UepButton(
          label: l10n.commonCancel,
          variant: UepButtonVariant.outline,
          small: true,
          onPressed: () => Navigator.of(context).pop(),
        ),
        // **一律可按**：停用的按鈕按下去什麼都不會發生，而「不能送」的理由
        // 在畫面上另一個地方——按了沒反應與功能壞掉分不出來（09/17 實機）
        UepButton(
          label: l10n.commonSubmit,
          small: true,
          onPressed: _submit,
        ),
      ],
    );
  }
}
