import 'package:flutter/material.dart';

import '../core/theme/uep_theme.dart';
import '../core/theme/uep_tokens.dart';
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
  });

  final Question question;

  /// (kind, answer)：kind 為 option 或 free_text。
  final Future<void> Function(String kind, String answer) onAnswer;
  final Future<void> Function() onSkip;

  @override
  State<QuestionCard> createState() => _QuestionCardState();
}

class _QuestionCardState extends State<QuestionCard> {
  final _controller = TextEditingController();
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
                    onTap: () => _run(
                        () => widget.onAnswer('option', option.label)),
                  ),
              ],
            ),
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

  void _submitText() {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    _run(() => widget.onAnswer('free_text', text));
  }
}

class _OptionChip extends StatelessWidget {
  const _OptionChip({
    required this.option,
    required this.enabled,
    required this.onTap,
  });

  final QuestionOption option;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    return Opacity(
      opacity: enabled ? 1 : 0.5,
      child: Material(
        color: s.bgSoft,
        borderRadius: BorderRadius.circular(999),
        child: InkWell(
          borderRadius: BorderRadius.circular(999),
          onTap: enabled ? onTap : null,
          child: Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: s.lineStrong),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(option.label,
                    style: UepText.sans(size: 12.5, color: s.ink)),
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
