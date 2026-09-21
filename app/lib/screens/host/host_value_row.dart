/// 「這台機器」頁的值列：左邊 mono 小標，右邊一格深色圓角框。
///
/// 唯讀的（[CopyRow]）與可改的（[EditRow]）**用同一個外殼**。並排時只要
/// 有一邊自己畫，畫面上立刻看得出是兩個人做的——設定區原本用底線式輸入框，
/// 就在「連線資訊」那幾列正下方，兩種輸入框中間只隔一條分隔線。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/uep_theme.dart';
import '../../core/theme/uep_tokens.dart';
import '../../l10n/l10n.dart';

/// 標籤欄的寬度。兩種列共用，否則右邊那格的左緣會差開。
const double kValueRowLabelWidth = 92;

/// 值那一格的外殼：深色底、細框、圓角 5。
class _ValueBox extends StatelessWidget {
  const _ValueBox({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
      decoration: BoxDecoration(
        color: s.bgSunken,
        border: Border.all(color: s.line),
        borderRadius: BorderRadius.circular(5),
      ),
      child: child,
    );
  }
}

class _RowLabel extends StatelessWidget {
  const _RowLabel({required this.label, this.tooltip});

  final String label;

  /// 滑過去才看得到的東西（例如這一格在 `.env` 裡叫什麼）。
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final text = Text(label,
        style: UepText.fieldLabel(color: context.uep.inkMute));
    return SizedBox(
      width: kValueRowLabelWidth,
      child: tooltip == null ? text : Tooltip(message: tooltip!, child: text),
    );
  }
}

/// 唯讀的一列：看得到、複製得走，改不了。
class CopyRow extends StatefulWidget {
  const CopyRow(
      {super.key,
      required this.label,
      required this.value,
      this.secret = false});

  final String label;
  final String value;

  /// token 這種東西預設遮起來——這個畫面很可能在螢幕分享或截圖裡。
  /// 遮的是顯示，不是複製：按鈕照樣把真值放進剪貼簿。
  final bool secret;

  @override
  State<CopyRow> createState() => _CopyRowState();
}

class _CopyRowState extends State<CopyRow> {
  bool _revealed = false;
  bool _copied = false;

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    final hidden = widget.secret && !_revealed;
    return Row(children: [
      _RowLabel(label: widget.label),
      Expanded(
        child: _ValueBox(
          child: Text(
            hidden ? '•' * 24 : widget.value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: UepText.code(size: 12.5, color: s.ink),
          ),
        ),
      ),
      if (widget.secret)
        IconButton(
          tooltip: _revealed
              ? AppLocalizations.of(context).commonHide
              : AppLocalizations.of(context).commonShow,
          icon: Icon(_revealed ? Icons.visibility_off : Icons.visibility,
              size: 16, color: s.inkMute),
          onPressed: () => setState(() => _revealed = !_revealed),
        ),
      IconButton(
        tooltip: _copied
            ? AppLocalizations.of(context).commonCopied
            : AppLocalizations.of(context).commonCopy,
        icon: Icon(_copied ? Icons.check : Icons.copy,
            size: 16, color: _copied ? UepColors.success : s.inkMute),
        onPressed: () async {
          await Clipboard.setData(ClipboardData(text: widget.value));
          if (!mounted) return;
          setState(() => _copied = true);
          // 回到原狀，否則下一次複製看不出來有沒有成功
          await Future<void>.delayed(const Duration(seconds: 2));
          if (mounted) setState(() => _copied = false);
        },
      ),
    ]);
  }
}

/// 可改的一列。外殼與 [CopyRow] 同一個，右邊那格裡換成輸入框。
///
/// 沒有圖示的那幾列也要留出圖示的寬度，否則同一區裡有 token 與沒 token 的
/// 列，右緣會差開一大截。
class EditRow extends StatelessWidget {
  const EditRow({
    super.key,
    required this.label,
    this.tooltip,
    this.controller,
    this.child,
    this.fieldKey,
    this.hint,
    this.enabled = true,
    this.obscure = false,
    this.numeric = false,
    this.onRevealToggle,
    this.onChanged,
    this.errorText,
    this.trailingSlots = 2,
  });

  final String label;

  /// 滑過去才看得到的東西（例如這一格在 `.env` 裡叫什麼）。
  final String? tooltip;

  final TextEditingController? controller;

  /// 不是輸入框的時候（下拉選單）放這個。
  final Widget? child;

  final Key? fieldKey;
  final String? hint;
  final bool enabled;
  final bool obscure;
  final bool numeric;

  /// 有值就畫一顆眼睛。
  final VoidCallback? onRevealToggle;

  final ValueChanged<String>? onChanged;

  /// 欄位下面那句短話。
  final String? errorText;

  /// 右邊要留幾個圖示的位置（[CopyRow] 最多兩個：眼睛與複製）。
  final int trailingSlots;

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    final l10n = AppLocalizations.of(context);
    final icons = <Widget>[
      if (onRevealToggle != null)
        IconButton(
          tooltip: obscure ? l10n.commonShow : l10n.commonHide,
          icon: Icon(obscure ? Icons.visibility : Icons.visibility_off,
              size: 16, color: s.inkMute),
          onPressed: onRevealToggle,
        ),
    ];
    // IconButton 在這個字級下是 40 寬；空位用一樣寬的盒子占著
    final padding = trailingSlots - icons.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          _RowLabel(label: label, tooltip: tooltip),
          Expanded(
            child: _ValueBox(
              child: child ??
                  TextField(
                    key: fieldKey,
                    controller: controller,
                    enabled: enabled,
                    obscureText: obscure,
                    keyboardType: numeric ? TextInputType.number : null,
                    style: UepText.code(size: 12.5, color: s.ink),
                    decoration: InputDecoration(
                      isDense: true,
                      isCollapsed: true,
                      border: InputBorder.none,
                      hintText: hint,
                      hintStyle:
                          UepText.serif(size: 12.5, color: s.inkMute),
                    ),
                    onChanged: onChanged,
                  ),
            ),
          ),
          ...icons,
          for (var i = 0; i < padding; i++) const SizedBox(width: 40),
        ]),
        if (errorText != null)
          Padding(
            padding: const EdgeInsets.only(
                left: kValueRowLabelWidth, top: 4, bottom: 2),
            child: Text(errorText!,
                style: UepText.serif(size: 12.5, color: UepColors.error)),
          ),
      ],
    );
  }
}
