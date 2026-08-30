import 'package:flutter/material.dart';

import '../core/theme/uep_theme.dart';
import '../core/theme/uep_tokens.dart';
import '../api/attachments_api.dart';
import '../models/question.dart';
import 'uep_button.dart';

/// agent 指名問「我」的問題卡。
///
/// 只出現在被問的人的畫面上，且**不在訊息流裡**——它是待辦而不是對話，
/// 混進時間軸會被後續訊息推走，那正是這個機制要避免的事（問題被淹沒，
/// agent 只好在自己的 session 裡再問一次）。
///
/// 「略過」與放著不管是兩件事：略過會明確告訴 agent 改用它原本的方式問，
/// 放著不管則讓它繼續等。所以略過必須是一個看得見、按得到的動作。
class QuestionCard extends StatefulWidget {
  const QuestionCard({
    super.key,
    required this.question,
    required this.onAnswer,
    required this.onSkip,
    this.onPickFiles,
  });

  final Question question;

  /// (kind, answer, selected, attachmentIds)：kind 為 option 或 free_text。
  /// [selected] 只有複選題會有值；[attachmentIds] 是隨答案附上的檔案。
  final Future<void> Function(
    String kind,
    String answer,
    List<String> selected,
    List<String> attachmentIds,
  ) onAnswer;
  final Future<void> Function() onSkip;

  /// 選檔並上傳，回傳已上傳的附件。上傳邏輯留在聊天畫面（它已經有一整套
  /// 進度與錯誤處理），這張卡只負責顯示與送出。null＝不提供附加檔案。
  final Future<List<UploadedAttachment>> Function()? onPickFiles;

  @override
  State<QuestionCard> createState() => _QuestionCardState();
}

class _QuestionCardState extends State<QuestionCard> {
  final _controller = TextEditingController();
  final _picked = <String>{};
  final _files = <UploadedAttachment>[];
  bool _uploading = false;
  bool _busy = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } finally {
      // 送出後卡片通常就消失了（server 推的快照不再包含它），
      // 但失敗時要能重試，所以仍要解除忙碌狀態
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    final q = widget.question;
    final canSubmitFreeText = q.allowFreeText && !_busy;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: s.bgCard,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: s.lineStrong),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(Icons.help_outline, size: 15, color: s.inkSoft),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                q.askerName == null ? '有人在問你' : '${q.askerName} 在問你',
                style: UepText.mono(
                    size: 9.5, color: s.inkMute, letterSpacing: 1.4),
              ),
            ),
          ]),
          const SizedBox(height: 10),
          Text(q.prompt, style: UepText.sans(size: 14, color: s.ink)),
          const SizedBox(height: 14),
          if (q.options.isNotEmpty) ...[
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final option in q.options)
                  _OptionChip(
                    option: option,
                    enabled: !_busy,
                    // 複選：點一下是勾選，要按「送出所選」才算數。單選維持
                    // 點了就送——多一個確認步驟只會讓最常見的情況變慢
                    selected: q.multiSelect && _picked.contains(option.label),
                    onTap: q.multiSelect
                        ? () => setState(() =>
                            _picked.contains(option.label)
                                ? _picked.remove(option.label)
                                : _picked.add(option.label))
                        : () => _run(() => widget.onAnswer(
                            'option', option.label, const [], _fileIds())),
                  ),
              ],
            ),
            if (q.multiSelect) ...[
              const SizedBox(height: 10),
              Row(children: [
                Text(
                  _picked.isEmpty ? '可以複選' : '已選 ${_picked.length} 項',
                  style: UepText.mono(size: 9.5, color: s.inkMute,
                      letterSpacing: 1.2),
                ),
                const Spacer(),
                UepButton(
                  label: '送出所選',
                  small: true,
                  onPressed: (_busy || _picked.isEmpty)
                      ? null
                      : () => _run(() => widget.onAnswer(
                          'option', '', _picked.toList(), _fileIds())),
                ),
              ]),
            ],
            if (q.allowFreeText) const SizedBox(height: 12),
          ],
          if (q.allowFreeText)
            Row(children: [
              Expanded(
                child: TextField(
                  controller: _controller,
                  enabled: !_busy,
                  style: UepText.sans(size: 13, color: s.ink),
                  decoration: InputDecoration(
                    hintText: q.options.isEmpty ? '你的回答…' : '或自己寫…',
                    hintStyle: UepText.sans(size: 13, color: s.inkMute),
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 10),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(color: s.line),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(color: s.line),
                    ),
                  ),
                  onSubmitted: canSubmitFreeText ? (_) => _submitText() : null,
                ),
              ),
              const SizedBox(width: 8),
              UepButton(
                label: '送出',
                small: true,
                onPressed: canSubmitFreeText ? _submitText : null,
              ),
            ]),
          if (widget.onPickFiles != null) ...[
            const SizedBox(height: 10),
            Row(children: [
              TextButton.icon(
                onPressed: (_busy || _uploading) ? null : _pickFiles,
                icon: Icon(Icons.attach_file, size: 14, color: s.inkMute),
                label: Text(
                  _uploading ? '上傳中…' : '附加檔案',
                  style: UepText.mono(size: 9.5, color: s.inkMute,
                      letterSpacing: 1.2),
                ),
              ),
              if (_files.isNotEmpty)
                Expanded(
                  child: Text(
                    _files.map((f) => f.filename).join('、'),
                    overflow: TextOverflow.ellipsis,
                    style: UepText.mono(size: 9.5, color: s.ink),
                  ),
                ),
              if (_files.isNotEmpty)
                IconButton(
                  onPressed: _busy ? null : () => setState(_files.clear),
                  icon: Icon(Icons.close, size: 14, color: s.inkMute),
                  tooltip: '清掉附件',
                ),
            ]),
          ],
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: _busy ? null : () => _run(widget.onSkip),
              child: Text(
                '略過，改在原本的對話裡問我',
                style: UepText.mono(
                    size: 9.5, color: s.inkMute, letterSpacing: 1.2),
              ),
            ),
          ),
        ],
      ),
    );
  }

  List<String> _fileIds() => _files.map((f) => f.id).toList();

  Future<void> _pickFiles() async {
    final pick = widget.onPickFiles;
    if (pick == null) return;
    setState(() => _uploading = true);
    try {
      final got = await pick();
      if (mounted) setState(() => _files.addAll(got));
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  void _submitText() {
    final text = _controller.text.trim();
    // 附了檔案就不必再逼人打字——「就是這張圖」本身就是答案
    if (text.isEmpty && _files.isEmpty) return;
    _run(() => widget.onAnswer(
        'free_text', text.isEmpty ? '（見附件）' : text, const [], _fileIds()));
  }
}

class _OptionChip extends StatelessWidget {
  const _OptionChip({
    required this.option,
    required this.enabled,
    required this.onTap,
    this.selected = false,
  });

  final QuestionOption option;
  final bool enabled;
  final VoidCallback onTap;

  /// 複選題的勾選狀態。單選題永遠 false——它點了就送，沒有中間狀態。
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    return Opacity(
      opacity: enabled ? 1 : 0.5,
      child: Material(
        color: selected ? s.bgSunken : s.bgSoft,
        borderRadius: BorderRadius.circular(999),
        child: InkWell(
          borderRadius: BorderRadius.circular(999),
          onTap: enabled ? onTap : null,
          child: Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(999),
              border: Border.all(
                  color: selected ? UepColors.gold : s.lineStrong,
                  width: selected ? 1.5 : 1),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(mainAxisSize: MainAxisSize.min, children: [
                  if (selected)
                    Padding(
                      padding: const EdgeInsets.only(right: 5),
                      child: Icon(Icons.check,
                          size: 13, color: UepColors.gold),
                    ),
                  Text(option.label,
                      style: UepText.sans(size: 12.5, color: s.ink)),
                ]),
                if (option.description.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      option.description,
                      style: UepText.sans(size: 10.5, color: s.inkMute),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
