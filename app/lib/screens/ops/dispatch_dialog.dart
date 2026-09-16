import 'package:flutter/material.dart';

import '../../core/theme/uep_theme.dart';
import '../../core/theme/uep_tokens.dart';
import '../../models/agent_run.dart';
import '../../widgets/kind_badge.dart';
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

/// 對一個階段或一張卡派工（REMOTE-OPS-PLAN §6.2）。
///
/// 人類**不寫自由 prompt**：選模板 + 選目標 + 一段簡述（≤2000）。目標是
/// 呼叫端給的（抽屜裡的那張卡、那個階段），這裡不讓人改——能改的話它就
/// 變成了「派工到任何地方」，而那正是模板化要擋掉的事。
Future<DispatchRequest?> showDispatchDialog(
  BuildContext context, {
  required String targetLabel,
  required List<String> projects,
}) =>
    showDialog<DispatchRequest>(
      context: context,
      builder: (context) =>
          DispatchDialog(targetLabel: targetLabel, projects: projects),
    );

class DispatchDialog extends StatefulWidget {
  const DispatchDialog({
    super.key,
    required this.targetLabel,
    required this.projects,
  });

  /// 要派給誰做的那個東西，寫在對話框頂上。派工是**對一個目標**做的，
  /// 而選完模板之後最容易忘的正是自己在哪張卡上按的。
  final String targetLabel;

  /// 可選的專案。
  ///
  /// **來自執行器宣告的 `projects`**（儀表板），不是 App 寫死的清單：Hub
  /// 建單時用同一份資料判 `project_not_served`，兩邊各寫一份的話，畫面上
  /// 選得到的專案會被 Hub 退，而使用者看不出自己選錯了什麼。
  final List<String> projects;

  @override
  State<DispatchDialog> createState() => _DispatchDialogState();
}

class _DispatchDialogState extends State<DispatchDialog> {
  final _brief = TextEditingController();
  late String _kind = kRunTemplates.first.kind;
  late String? _project =
      widget.projects.length == 1 ? widget.projects.first : null;
  int _priority = 0;
  String? _error;

  @override
  void initState() {
    super.initState();
    // 計數要跟著字走
    _brief.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _brief.dispose();
    super.dispose();
  }

  void _submit() {
    final project = _project;
    if (project == null || project.isEmpty) {
      setState(() => _error = '請先選一個專案');
      return;
    }
    final brief = _brief.text.trim();
    // Hub 也擋（`max_length=2000`），這裡先擋是為了不要讓人打完 2500 字
    // 才在送出時被退回來
    if (brief.length > kRunBriefMaxLength) {
      setState(() => _error = '簡述超過 $kRunBriefMaxLength 字');
      return;
    }
    Navigator.of(context).pop(DispatchRequest(
        kind: _kind, project: project, brief: brief, priority: _priority));
  }

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    final noProject = widget.projects.isEmpty;
    return AlertDialog(
      title: Text('派工', style: UepText.display(size: 24, color: s.inkTitle)),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Align(
              alignment: Alignment.centerLeft,
              child: Text('目標：${widget.targetLabel}',
                  style: UepText.serif(
                      size: 12.5, color: s.inkSoft, height: 1.5)),
            ),
            const SizedBox(height: 14),
            Align(
              alignment: Alignment.centerLeft,
              child: MonoLabel('模板', color: s.inkSoft, letterSpacing: 1.4),
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
                              size: 12.5,
                              weight: _kind == t.kind
                                  ? FontWeight.w600
                                  : FontWeight.w400,
                              color: s.ink)),
                      const SizedBox(height: 3),
                      Text(t.summary,
                          style: UepText.serif(
                              size: 11, color: s.inkMute, height: 1.4)),
                    ],
                  ),
                ),
              ),
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerLeft,
              child: MonoLabel('專案', color: s.inkSoft, letterSpacing: 1.4),
            ),
            const SizedBox(height: 7),
            if (noProject)
              // 停用要說出理由，而且理由要能導向下一步——這一條的下一步在
              // 那台機器上，不在這個畫面裡
              Align(
                alignment: Alignment.centerLeft,
                child: Text('沒有執行器宣告任何專案。先確認執行器上線，'
                    '並把專案加進它的 projects 白名單。',
                    style: UepText.serif(
                        size: 11.5, color: UepColors.errorText, height: 1.5)),
              )
            else
              Align(
                alignment: Alignment.centerLeft,
                child: DropdownButton<String>(
                  value: _project,
                  hint: Text('選一個專案',
                      style: UepText.sans(size: 12.5, color: s.inkMute)),
                  items: [
                    for (final p in widget.projects)
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
              child: MonoLabel('簡述（給 agent 的任務描述）',
                  color: s.inkSoft, letterSpacing: 1.4),
            ),
            const SizedBox(height: 7),
            TextField(
              controller: _brief,
              maxLines: 5,
              style: UepText.sans(size: 12.5, color: s.ink),
              decoration: InputDecoration(
                isDense: true,
                border: const OutlineInputBorder(),
                hintText: '要做什麼、從哪裡看起、什麼算做完…',
                hintStyle: UepText.serif(size: 12, color: s.inkMute),
              ),
            ),
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerRight,
              child: Text('${_brief.text.trim().length} / $kRunBriefMaxLength',
                  style: UepText.mono(
                      size: 9.5,
                      color: _brief.text.trim().length > kRunBriefMaxLength
                          ? UepColors.error
                          : s.inkMute)),
            ),
            const SizedBox(height: 10),
            Row(children: [
              MonoLabel('優先', color: s.inkSoft, letterSpacing: 1.4),
              const SizedBox(width: 10),
              // 佇列是 priority DESC + position ASC。數字大的先做
              DropdownButton<int>(
                value: _priority,
                items: [
                  for (final p in [0, 1, 2, 3])
                    DropdownMenuItem(
                      value: p,
                      child: Text(p == 0 ? '一般' : '插隊 $p',
                          style: UepText.sans(size: 12.5, color: s.ink)),
                    ),
                ],
                onChanged: (v) => setState(() => _priority = v ?? 0),
              ),
            ]),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(_error!,
                    style: UepText.serif(
                        size: 12.5, color: UepColors.errorText, height: 1.5)),
              ),
            ],
          ]),
        ),
      ),
      actions: [
        UepButton(
          label: '取消',
          variant: UepButtonVariant.outline,
          small: true,
          onPressed: () => Navigator.of(context).pop(),
        ),
        UepButton(
          label: '送出',
          small: true,
          onPressed: noProject ? null : _submit,
        ),
      ],
    );
  }
}
