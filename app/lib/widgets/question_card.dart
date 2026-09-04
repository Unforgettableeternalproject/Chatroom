import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme/uep_theme.dart';
import '../core/theme/uep_tokens.dart';
import '../api/attachments_api.dart';
import '../models/question.dart';
import '../state/composer_drafts.dart';
import 'uep_button.dart';

/// agent 指名問「我」的問題卡。
///
/// 只出現在被問的人的畫面上，且**不在訊息流裡**——它是待辦而不是對話，
/// 混進時間軸會被後續訊息推走，那正是這個機制要避免的事（問題被淹沒，
/// agent 只好在自己的 session 裡再問一次）。
///
/// 「略過」與放著不管是兩件事：略過會明確告訴 agent 改用它原本的方式問，
/// 放著不管則讓它繼續等。所以略過必須是一個看得見、按得到的動作。
class QuestionCard extends ConsumerStatefulWidget {
  const QuestionCard({
    super.key,
    required this.question,
    required this.onAnswer,
    required this.onSkip,
    this.onPickFiles,
  });

  final Question question;

  /// (kind, answer, selected, attachmentIds, extra)：kind 為 option 或
  /// free_text。[selected] 只有複選題會有值；[attachmentIds] 是隨答案附上的
  /// 檔案；[extra] 是複選之外自己補的話，**只跟著 option 送**。
  final Future<void> Function(
    String kind,
    String answer,
    List<String> selected,
    List<String> attachmentIds,
    String extra,
  ) onAnswer;
  final Future<void> Function() onSkip;

  /// 選檔並上傳，回傳已上傳的附件。上傳邏輯留在聊天畫面（它已經有一整套
  /// 進度與錯誤處理），這張卡只負責顯示與送出。null＝不提供附加檔案。
  final Future<List<UploadedAttachment>> Function()? onPickFiles;

  @override
  ConsumerState<QuestionCard> createState() => _QuestionCardState();
}

class _QuestionCardState extends ConsumerState<QuestionCard> {
  /// 🔴 **草稿存在 App 級，不是這顆 State 裡。**
  ///
  /// 這張卡躺在聊天畫面一個有高度上限的 `ListView` 裡（`chat_screen.dart`
  /// :2596，maxHeight 420）——待答問題多到要捲動時，**捲出視窗的卡會被
  /// 回收，打到一半的答案跟著消失**（@開發Novia (除錯) #414）。
  ///
  /// 與訊息草稿、想法板輸入框是同一個病因的第三次：**不是忘了存，
  /// 是存在一個生命週期比它短的地方。**
  late final _controller = TextEditingController(
      text: ref.read(questionDraftsProvider.notifier).of(widget.question.id))
    ..addListener(_saveDraft);
  final _picked = <String>{};
  final _files = <UploadedAttachment>[];
  bool _uploading = false;
  bool _busy = false;

  @override
  void dispose() {
    // ⚠️ **不在這裡清草稿**——dispose 的原因多半是「捲出去了」而不是
    // 「答完了」，清掉的話這個修法就等於沒做
    _controller.removeListener(_saveDraft);
    _controller.dispose();
    super.dispose();
  }

  void _saveDraft() => ref
      .read(questionDraftsProvider.notifier)
      .set(widget.question.id, _controller.text);

  /// 🔴 **同一顆 State 換去服務另一題時，輸入框要跟著換那一題的草稿。**
  ///
  /// 卡片沒有 key（或有 key 但被重用）時，Flutter 會把這顆 State 交給下一題
  /// ——而 `late final` 的 controller 只建一次 ⇒ **第一題打的字會出現在
  /// 第二題的輸入框裡，按下送出就送到錯的問題上。**
  ///
  /// 這比「草稿消失」嚴重：消失看得見，串位不會——送出去的是一段讀起來
  /// 完全合理、只是答錯題的話。
  @override
  void didUpdateWidget(QuestionCard old) {
    super.didUpdateWidget(old);
    if (old.question.id == widget.question.id) return;
    // 先把手上這份存回**舊那題**，再換成新那題的
    ref.read(questionDraftsProvider.notifier).set(old.question.id, _controller.text);
    _controller.removeListener(_saveDraft);
    _controller.text =
        ref.read(questionDraftsProvider.notifier).of(widget.question.id);
    _controller.addListener(_saveDraft);
    _picked.clear();
    _files.clear();
  }

  bool get _hasText => _controller.text.trim().isNotEmpty;
  bool get _hasPicks => widget.question.multiSelect && _picked.isNotEmpty;

  bool get _canSend => !_busy && (_hasText || _hasPicks);

  /// 按鈕的字要說出**按下去會送什麼**。三種情形三句話——寫死一個「送出」
  /// 的話，選了三張又打了字的人按下去之前不知道自己送的是哪一種。
  String get _sendLabel {
    if (_hasPicks && _hasText) return '送出所選 ${_picked.length} ＋補充';
    if (_hasPicks) return '送出所選 ${_picked.length}';
    return '送出';
  }

  /// 送出。
  ///
  /// **選項與補充是一起送的**（Hub `87cc53f` 的 `extra`）：`kind='option'`
  /// 帶 `extra`，`answer_options` 那份仍只有真選項——讀它的 agent 對
  /// 「他是從我給的清單裡選的」那份信任不會被自訂文字稀釋。
  ///
  /// ⚠️ `extra` **不能跟 free_text 一起送**（422 `extra_needs_option`）：
  /// 沒有選任何項時，打的字本身就是答案，那時走 free_text。
  void _send() {
    if (!_hasPicks) {
      _submitText();
      return;
    }
    _run(() => widget.onAnswer(
          'option',
          '',
          _picked.toList(),
          _fileIds(),
          _controller.text.trim(),
        ));
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
      // 答出去了才清草稿。**失敗時不清**——那正是最需要它還在的時候
      // （送失敗的長文如果連著草稿一起沒了，人要從頭打一遍）
      ref.read(questionDraftsProvider.notifier).clear(widget.question.id);
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
                        // 單選維持「點了就送」，但**打過的字要一起帶走**。
                        // Hub 的單選也吃 option + extra，而使用者先打字再點
                        // 選項是很自然的順序——把那段字默默丟掉，他不會發現
                        // 自己補的話沒送出去
                        : () => _run(() => widget.onAnswer(
                            'option',
                            option.label,
                            const [],
                            _fileIds(),
                            _controller.text.trim())),
                  ),
              ],
            ),
            if (q.multiSelect) ...[
              const SizedBox(height: 10),
              Row(children: [
                Text(
                  _picked.isEmpty
                      ? '可以複選'
                      : (q.allowFreeText
                          // 打了字時要講出來會一起送——上一版是「取代」，
                          // 那是 Hub 沒有 extra 之前的限制，不是我們想要的行為
                          ? '已選 ${_picked.length} 項，補充會一併帶上'
                          : '已選 ${_picked.length} 項'),
                  style: UepText.mono(size: 9.5, color: s.inkMute,
                      letterSpacing: 1.2),
                ),
                const Spacer(),
                // 有自由文字欄時**這裡不出按鈕**——下面那顆會一併處理。
                // 兩顆送出並排時，看的人得先讀懂它們差在哪才敢按，
                // 而它們送出的是互斥的兩種答案（option / free_text），
                // 不是「送這個」與「送那個」的並列選擇
                if (!q.allowFreeText)
                  UepButton(
                    label: '送出所選',
                    small: true,
                    onPressed: (_busy || _picked.isEmpty)
                        ? null
                        : () => _run(() => widget.onAnswer('option', '',
                            _picked.toList(), _fileIds(), '')),
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
                  // 打字要重畫：按鈕的字與「會取代所選」那句提示都看它
                  onChanged: (_) => setState(() {}),
                  onSubmitted: _canSend ? (_) => _send() : null,
                ),
              ),
              const SizedBox(width: 8),
              UepButton(
                label: _sendLabel,
                small: true,
                onPressed: _canSend ? _send : null,
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
    _run(() => widget.onAnswer('free_text',
        text.isEmpty ? '（見附件）' : text, const [], _fileIds(), ''));
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
