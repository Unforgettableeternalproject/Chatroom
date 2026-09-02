import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/mention_groups.dart';
import '../core/theme/uep_theme.dart';
import '../core/theme/uep_tokens.dart';
import '../models/message.dart';
import '../models/participant.dart';
import 'composer_attachments.dart';
import 'kind_badge.dart';
import 'uep_button.dart';

/// 從送出內容萃取被 @ 提及的成員名單。
///
/// 必須最長優先比對——房內天然存在前綴重名（Nova 與 Nova-2 由 Hub 自動編號），
/// 用 contains('@$name') 會讓「@Nova-2」同時 ping 到 Nova。
/// 比對成功後還要檢查右邊界：下一個字元若仍是名字字元（英數 / - / _），
/// 代表 @ 後面其實是更長的字串（@Nova-25 不算提及 Nova-2）。
List<String> extractMentions(String content, Iterable<String> memberNames) {
  final names = memberNames.toList()
    ..sort((a, b) => b.length.compareTo(a.length));
  final nameChar = RegExp(r'[A-Za-z0-9_-]');
  final found = <String>{};
  var i = 0;
  while (i < content.length) {
    if (content[i] != '@') {
      i++;
      continue;
    }
    var matched = false;
    for (final name in names) {
      if (name.isEmpty) continue;
      final end = i + 1 + name.length;
      if (end > content.length) continue;
      if (content.substring(i + 1, end) != name) continue;
      if (end < content.length && nameChar.hasMatch(content[end])) continue;
      found.add(name);
      i = end;
      matched = true;
      break;
    }
    if (!matched) i++;
  }
  return found.toList();
}

/// 訊息輸入區：回覆預覽 + @ 自動完成 + ENTER 送出 / SHIFT+ENTER 換行。
class MessageComposer extends StatefulWidget {
  const MessageComposer({
    super.key,
    required this.members,
    required this.onSend,
    this.enabled = true,
    this.replyTarget,
    this.onCancelReply,
    this.editTarget,
    this.onCancelEdit,
    this.attachments = const [],
    this.onPickFiles,
    this.onPasteImage,
    this.onRemoveAttachment,
    this.onRetryAttachment,
    this.initialText = '',
    this.onTextChanged,
  });

  /// 房內 active 成員（@ 選單只列這些，P3-07 條件 2）。
  final List<Participant> members;
  final Future<void> Function(String content, List<String> mentions) onSend;
  final bool enabled;
  final Message? replyTarget;
  final VoidCallback? onCancelReply;

  /// 正在編輯的訊息。與 [replyTarget] **同構但互斥**——回覆是「針對那則說
  /// 一句新的」，編輯是「把那則換掉」，同時成立沒有意義，而且送出時分不出
  /// 該走哪條路。外層設定其中一個時要清掉另一個。
  final Message? editTarget;
  final VoidCallback? onCancelEdit;

  /// 待送附件。上傳流程由外層（持有 provider 的畫面）負責，這裡只負責畫
  /// 與觸發——輸入列是純呈現元件，不該知道 Hub 的存在。
  final List<ComposerAttachment> attachments;
  final VoidCallback? onPickFiles;

  /// Ctrl+V：回傳 true 表示剪貼簿裡真的有圖並已接手，此時不讓貼上事件
  /// 繼續傳給 TextField（否則會同時貼進一張圖和一段檔名文字）。
  final Future<bool> Function()? onPasteImage;
  final void Function(ComposerAttachment)? onRemoveAttachment;
  final void Function(ComposerAttachment)? onRetryAttachment;

  /// 進場時輸入框裡就該有的字（這個房間上次沒說完的話）。
  ///
  /// **只在 initState 讀一次。** 之後的每一次輸入都是使用者在打字，拿外面
  /// 的值再蓋回去會把游標推到別的位置、也會吃掉正在輸入的組字。
  final String initialText;

  /// 每次內容變動時回報給外層存起來。
  ///
  /// 存放的地方是外層的事——這個 widget 是純呈現元件，不知道有房間這回事，
  /// 也就不該知道草稿該存到哪一格去。
  final ValueChanged<String>? onTextChanged;

  @override
  State<MessageComposer> createState() => _MessageComposerState();
}

class _MessageComposerState extends State<MessageComposer> {
  late final _controller = TextEditingController(text: widget.initialText);
  final _focus = FocusNode();
  final _link = LayerLink();
  final _overlayController = OverlayPortalController();
  /// 補全候選：房內成員，或 `all` / `agents` / `humans` 這種群組保留字。
  /// 群組項的 [_MentionOption.participant] 是 null。
  List<_MentionOption> _candidates = const [];
  int _mentionStart = -1;
  bool _sending = false;

  /// 輸入框是否有內容。送出鈕的可用狀態靠它——直接在 build 讀 controller
  /// 的話，打字不會觸發重建，按鈕會一直停在剛進畫面時的狀態。
  bool _hasText = false;

  @override
  void initState() {
    super.initState();
    _hasText = _controller.text.trim().isNotEmpty;
    _controller.addListener(_onTextChanged);
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(MessageComposer old) {
    super.didUpdateWidget(old);
    final target = widget.editTarget;
    if (target != null && target.id != old.editTarget?.id) {
      // 編輯是「把那則換掉」，所以輸入框要**帶著原文**進場——空白起手等於
      // 逼使用者重打一遍，而他多半只是要改一個字
      _controller.text = target.content;
      _controller.selection =
          TextSelection.collapsed(offset: target.content.length);
      _focus.requestFocus();
    } else if (target == null && old.editTarget != null) {
      // 取消編輯要把草稿清掉：留著的話下一則新訊息會帶著上一則的內容送出
      _controller.clear();
    }
  }

  void _onTextChanged() {
    final text = _controller.text;
    // 回報給外層存起來。**放在最前面**——下面每一條 early return 都是
    // 「@ 選單不用理它」的意思，不是「這次輸入不算數」。漏在某一條之後的話，
    // 游標跑到開頭、或使用者按了 ESC 收掉選單，那一次的字就不會被存下來
    widget.onTextChanged?.call(text);
    final hasText = text.trim().isNotEmpty;
    if (hasText != _hasText) setState(() => _hasText = hasText);
    final cursor = _controller.selection.baseOffset;
    if (cursor < 0) {
      _hideMentions();
      return;
    }
    // 從游標往回找最近的 @，中間不能有空白/換行
    var at = -1;
    for (var i = cursor - 1; i >= 0; i--) {
      final c = text[i];
      if (c == '@') {
        at = i;
        break;
      }
      if (c == ' ' || c == '\n') break;
    }
    if (at < 0) {
      _hideMentions();
      return;
    }
    final fragment = text.substring(at + 1, cursor).toLowerCase();
    final matches = <_MentionOption>[
      // 群組排在前面：它們是少數幾個固定的名字，而成員清單會很長。
      // 打了 `@a` 卻要捲過十個人名才看到 `all`，那個選單等於沒用
      for (final entry in kMentionGroups.entries)
        if (entry.key.startsWith(fragment))
          _MentionOption.group(entry.key, entry.value),
      for (final p in widget.members)
        if (p.isActive && p.displayName.toLowerCase().startsWith(fragment))
          _MentionOption.member(p),
    ];
    if (matches.isEmpty) {
      _hideMentions();
      return;
    }
    setState(() {
      _mentionStart = at;
      _candidates = matches;
    });
    _overlayController.show();
  }

  void _hideMentions() {
    if (_overlayController.isShowing) _overlayController.hide();
    _mentionStart = -1;
  }

  void _pickMention(_MentionOption option) {
    final text = _controller.text;
    final cursor = _controller.selection.baseOffset;
    final before = text.substring(0, _mentionStart);
    final after = text.substring(cursor);
    final inserted = '@${option.name} ';
    _controller.value = TextEditingValue(
      text: '$before$inserted$after',
      selection:
          TextSelection.collapsed(offset: before.length + inserted.length),
    );
    _hideMentions();
    _focus.requestFocus();
  }

  /// 送出時從文字內容萃取仍存在的 @成員 名單。
  ///
  /// 群組保留字一併送出去，**不在這裡展開**——Hub 才知道此刻房裡有誰，
  /// 而且 agent 透過 MCP 發的 `@all` 也得走同一條路。
  List<String> _extractMentions(String content) => extractMentions(
        content,
        [...widget.members.map((p) => p.displayName), ...kMentionGroups.keys],
      );

  /// 有附件還在傳（或傳失敗）時不讓送出。送出去的訊息只會帶已就緒的 id，
  /// 讓它送出等於默默把那個檔案丟掉——使用者會以為傳成功了。
  bool get _attachmentsSettled =>
      widget.attachments.every((a) => a.isReady);

  bool get _canSend =>
      widget.enabled &&
      !_sending &&
      _attachmentsSettled &&
      (_hasText || widget.attachments.isNotEmpty);

  Future<void> _send() async {
    if (!_canSend) return;
    var content = _controller.text.trim();
    if (content.isEmpty) {
      // Hub 的 content 是 min_length=1，純附件訊息必須有字。用檔名當說明，
      // 與 bridge 的 chatroom_send_file 同一套慣例。
      final first = widget.attachments.first.filename;
      content = widget.attachments.length == 1
          ? '（檔案）$first'
          : '（檔案）$first 等 ${widget.attachments.length} 個';
    }
    setState(() => _sending = true);
    try {
      await widget.onSend(content, _extractMentions(content));
      _controller.clear();
      _hideMentions();
    } finally {
      if (mounted) setState(() => _sending = false);
    }
    _focus.requestFocus();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final paste = widget.onPasteImage;
    if (paste != null &&
        event.logicalKey == LogicalKeyboardKey.keyV &&
        (HardwareKeyboard.instance.isControlPressed ||
            HardwareKeyboard.instance.isMetaPressed)) {
      // 剪貼簿是非同步讀的，這裡無法等結果再決定要不要放行。剪貼簿同時有
      // 圖與文字時（截圖工具常見）兩者都會進來——寧可多一段文字，也不要
      // 因為攔截而讓一般的文字貼上失效。
      paste();
      return KeyEventResult.ignored;
    }
    final isEnter = event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter;
    if (!isEnter) return KeyEventResult.ignored;
    if (HardwareKeyboard.instance.isShiftPressed) {
      return KeyEventResult.ignored; // SHIFT+ENTER → 換行
    }
    if (_overlayController.isShowing && _candidates.isNotEmpty) {
      _pickMention(_candidates.first);
      return KeyEventResult.handled;
    }
    _send();
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final s = context.uep;

    if (!widget.enabled) {
      return Container(
        padding: const EdgeInsets.symmetric(vertical: 20),
        decoration: BoxDecoration(
          color: s.bgSunken,
          border: Border(top: BorderSide(color: s.line)),
        ),
        child: Center(
          child: MonoLabel('此聊天室已封存，無法發言', size: 10, letterSpacing: 2.4),
        ),
      );
    }

    final reply = widget.replyTarget;
    final editing = widget.editTarget;

    return Container(
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 14),
      decoration: BoxDecoration(
        color: s.bgSoft,
        border: Border(top: BorderSide(color: s.line)),
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        ComposerAttachmentBar(
          attachments: widget.attachments,
          onRemove: widget.onRemoveAttachment ?? (_) {},
          onRetry: widget.onRetryAttachment ?? (_) {},
        ),
        if (editing != null) ...[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
            decoration: BoxDecoration(
              color: s.bgSunken,
              border: const Border(
                  left: BorderSide(color: UepColors.gold, width: 2)),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Row(children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('編輯 #${editing.seq}',
                        style: UepText.mono(
                            size: 9,
                            color: UepColors.gold,
                            letterSpacing: 1.0)),
                    const SizedBox(height: 2),
                    Text(
                      // 講出後果：編輯過的訊息會留下「已編輯」標記，
                      // 那不是可以偷偷改掉的東西
                      '送出後會取代原本的內容，並標記為已編輯',
                      style: UepText.serif(
                          size: 12, color: s.inkMute, height: 1.5),
                    ),
                  ],
                ),
              ),
              IconButton(
                onPressed: widget.onCancelEdit,
                icon: Icon(Icons.close, size: 14, color: s.inkMute),
                visualDensity: VisualDensity.compact,
              ),
            ]),
          ),
          const SizedBox(height: 10),
        ] else if (reply != null) ...[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
            decoration: BoxDecoration(
              color: s.bgSunken,
              border: const Border(
                  left: BorderSide(color: UepColors.gold, width: 2)),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Row(children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('回覆 ${reply.senderName ?? '（未知）'}',
                        style: UepText.mono(
                            size: 9,
                            color: UepColors.gold,
                            letterSpacing: 1.0)),
                    const SizedBox(height: 2),
                    Text(
                      reply.content,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: UepText.serif(
                          size: 12, color: s.inkMute, height: 1.5),
                    ),
                  ],
                ),
              ),
              IconButton(
                onPressed: widget.onCancelReply,
                icon: Icon(Icons.close, size: 14, color: s.inkMute),
                visualDensity: VisualDensity.compact,
              ),
            ]),
          ),
          const SizedBox(height: 10),
        ],
        Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          if (widget.onPickFiles != null) ...[
            IconButton(
              tooltip: '附加檔案（也可以直接把檔案拖進來、或貼上截圖）',
              onPressed: widget.onPickFiles,
              icon: Icon(Icons.attach_file, size: 18, color: s.inkMute),
            ),
            const SizedBox(width: 4),
          ],
          Expanded(
            child: CompositedTransformTarget(
              link: _link,
              child: OverlayPortal(
                controller: _overlayController,
                overlayChildBuilder: (context) => _buildMentionOverlay(context),
                child: Container(
                  decoration: BoxDecoration(
                    color: s.bgCard,
                    border: Border.all(color: s.lineStrong),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Focus(
                        onKeyEvent: _onKey,
                        child: TextField(
                          controller: _controller,
                          focusNode: _focus,
                          maxLines: 6,
                          minLines: 1,
                          style: UepText.serif(
                              size: 14, color: s.ink, height: 1.7),
                          decoration: InputDecoration(
                            isDense: true,
                            border: InputBorder.none,
                            hintText: '輸入訊息…　@ 提及成員，支援 Markdown',
                            hintStyle: UepText.serif(
                                size: 14, color: s.inkMute, height: 1.7),
                          ),
                        ),
                      ),
                      const SizedBox(height: 4),
                      MonoLabel('ENTER 送出 · SHIFT+ENTER 換行',
                          size: 8.5, letterSpacing: 1.2),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          UepButton(
            label: '送出 →',
            onPressed: _canSend ? _send : null,
          ),
        ]),
      ]),
    );
  }

  Widget _buildMentionOverlay(BuildContext context) {
    final s = context.uep;
    return CompositedTransformFollower(
      link: _link,
      targetAnchor: Alignment.topLeft,
      followerAnchor: Alignment.bottomLeft,
      offset: const Offset(0, -6),
      child: Align(
        alignment: Alignment.bottomLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 320, maxHeight: 220),
          child: Material(
            color: s.bgCard,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
              side: BorderSide(color: s.lineStrong),
            ),
            elevation: 12,
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.all(5),
              children: [
                for (final option in _candidates)
                  InkWell(
                    borderRadius: BorderRadius.circular(5),
                    onTap: () => _pickMention(option),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 9, vertical: 7),
                      decoration: BoxDecoration(
                        border: Border(
                          left: BorderSide(
                              color: option.participant == null
                                  // 群組不屬於任何 kind，用金色與人名區隔——
                                  // 它叫到的是一群人，該看得出來不一樣
                                  ? UepColors.gold
                                  : kindColor(option.participant!.kind,
                                      context: context),
                              width: 2),
                        ),
                      ),
                      child: Row(children: [
                        Text(option.name,
                            style: UepText.sans(
                                size: 12.5,
                                weight: FontWeight.w600,
                                color: s.inkTitle)),
                        const SizedBox(width: 9),
                        if (option.participant case final p?)
                          KindBadge(kind: p.kind, compact: true)
                        else
                          Text(option.description,
                              style:
                                  UepText.serif(size: 11, color: s.inkMute)),
                      ]),
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

/// 補全選單的一個候選：房內成員，或群組保留字（`all` / `agents` / `humans`）。
///
/// 刻意不用「名字是不是保留字」去事後判斷——那會在房裡真的有人叫 `all` 時
/// 選錯（Hub 端把它們列為保留字正是為了這個，但舊房間可能已經有那個名字）。
class _MentionOption {
  const _MentionOption.member(Participant this.participant)
      : _groupName = null,
        description = '';
  const _MentionOption.group(this._groupName, this.description)
      : participant = null;

  final Participant? participant;
  final String? _groupName;
  final String description;

  String get name => participant?.displayName ?? _groupName!;
}
