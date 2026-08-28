import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/theme/uep_theme.dart';
import '../core/theme/uep_tokens.dart';
import '../models/message.dart';
import '../models/participant.dart';
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
  });

  /// 房內 active 成員（@ 選單只列這些，P3-07 條件 2）。
  final List<Participant> members;
  final Future<void> Function(String content, List<String> mentions) onSend;
  final bool enabled;
  final Message? replyTarget;
  final VoidCallback? onCancelReply;

  @override
  State<MessageComposer> createState() => _MessageComposerState();
}

class _MessageComposerState extends State<MessageComposer> {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  final _link = LayerLink();
  final _overlayController = OverlayPortalController();
  List<Participant> _candidates = const [];
  int _mentionStart = -1;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onTextChanged);
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onTextChanged() {
    final text = _controller.text;
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
    final matches = widget.members
        .where((p) =>
            p.isActive &&
            p.displayName.toLowerCase().startsWith(fragment))
        .toList();
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

  void _pickMention(Participant p) {
    final text = _controller.text;
    final cursor = _controller.selection.baseOffset;
    final before = text.substring(0, _mentionStart);
    final after = text.substring(cursor);
    final inserted = '@${p.displayName} ';
    _controller.value = TextEditingValue(
      text: '$before$inserted$after',
      selection:
          TextSelection.collapsed(offset: before.length + inserted.length),
    );
    _hideMentions();
    _focus.requestFocus();
  }

  /// 送出時從文字內容萃取仍存在的 @成員 名單。
  List<String> _extractMentions(String content) =>
      extractMentions(content, widget.members.map((p) => p.displayName));

  Future<void> _send() async {
    final content = _controller.text.trim();
    if (content.isEmpty || _sending || !widget.enabled) return;
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

    return Container(
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 14),
      decoration: BoxDecoration(
        color: s.bgSoft,
        border: Border(top: BorderSide(color: s.line)),
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        if (reply != null) ...[
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
            onPressed: _sending ? null : _send,
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
                for (final p in _candidates)
                  InkWell(
                    borderRadius: BorderRadius.circular(5),
                    onTap: () => _pickMention(p),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 9, vertical: 7),
                      decoration: BoxDecoration(
                        border: Border(
                          left: BorderSide(
                              color: kindColor(p.kind, context: context),
                              width: 2),
                        ),
                      ),
                      child: Row(children: [
                        Text(p.displayName,
                            style: UepText.sans(
                                size: 12.5,
                                weight: FontWeight.w600,
                                color: s.inkTitle)),
                        const SizedBox(width: 9),
                        KindBadge(kind: p.kind, compact: true),
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
