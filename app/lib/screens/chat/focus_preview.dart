import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../core/theme/uep_theme.dart';
import '../../core/theme/uep_tokens.dart';
import '../../l10n/l10n.dart';
import '../../models/message.dart';

/// 目標離最新超過這麼多則，就改用預覽而不往回載。
///
/// 150 約是 `loadOlder` 三批（每批 50）。再遠的話真跳轉要載一串歷史、
/// 還要等 ListView 估高收斂（`_focusMaxAttempts`），慢又容易跳歪；
/// 150 以內已載入的 feed 通常本來就在手上，真跳轉很快。
const kFocusPreviewDistance = 150;

/// 預覽時取目標前後各幾則（server `around_seq` 的 radius）。
const kFocusPreviewRadius = 6;

/// 離底超過這麼多像素，就顯示「回到最新」。
const kJumpLatestThreshold = 400.0;

enum FocusMode { jump, preview }

/// 跳轉要真捲過去，還是開預覽。
///
/// [fromBottom] 是目標在已載入 feed 中離最新幾則（最新那則為 0）；
/// 不在 feed 中時 [inFeed] 為 false，一律預覽——不再為它往回載。
FocusMode decideFocusMode({
  required bool inFeed,
  required int fromBottom,
  int threshold = kFocusPreviewDistance,
}) => !inFeed || fromBottom > threshold ? FocusMode.preview : FocusMode.jump;

/// 「回到最新」該不該出現：預覽中一律出現；否則離底超過門檻。
bool shouldShowJumpLatest({
  required bool previewing,
  required bool hasClients,
  required double pixels,
  double threshold = kJumpLatestThreshold,
}) => previewing || (hasClients && pixels > threshold);

/// 遠距跳轉的預覽：目標清晰並播金色呼吸，其餘訊息模糊、稍暗。
///
/// 訊息本身由 [itemBuilder] 畫（與主列表同一套元件）。只有十幾則，所以
/// 用 Column 一次建完，`ensureVisible` 才一定量得到目標。
class FocusPreview extends StatefulWidget {
  const FocusPreview({
    super.key,
    required this.messages,
    required this.targetSeq,
    required this.itemBuilder,
  });

  /// 由舊到新。
  final List<Message> messages;
  final int targetSeq;
  final Widget Function(Message m, {required bool isTarget}) itemBuilder;

  @override
  State<FocusPreview> createState() => _FocusPreviewState();
}

class _FocusPreviewState extends State<FocusPreview> {
  final GlobalKey _targetKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _center();
  }

  @override
  void didUpdateWidget(FocusPreview old) {
    super.didUpdateWidget(old);
    if (old.targetSeq != widget.targetSeq) _center();
  }

  void _center() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _targetKey.currentContext;
      if (!mounted || ctx == null || !ctx.mounted) return;
      Scrollable.ensureVisible(ctx, alignment: 0.5);
    });
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      key: const Key('focus-preview'),
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final m in widget.messages)
            if (m.seq == widget.targetSeq)
              KeyedSubtree(
                key: _targetKey,
                child: widget.itemBuilder(m, isTarget: true),
              )
            else
              // 鄰近訊息只是脈絡：不可點、模糊、降亮度
              IgnorePointer(
                child: Opacity(
                  opacity: .5,
                  child: ImageFiltered(
                    key: Key('focus-preview-blur-${m.seq}'),
                    imageFilter: ui.ImageFilter.blur(
                      sigmaX: 3,
                      sigmaY: 3,
                      tileMode: TileMode.decal,
                    ),
                    child: widget.itemBuilder(m, isTarget: false),
                  ),
                ),
              ),
        ],
      ),
    );
  }
}

/// 聊天列表底部的「回到最新」。有未讀時顯示未讀數，否則只寫「回到最新」。
class JumpLatestButton extends StatelessWidget {
  const JumpLatestButton({
    super.key,
    required this.unread,
    required this.onTap,
  });

  final int unread;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    final l10n = AppLocalizations.of(context);
    return Positioned(
      bottom: 16,
      left: 0,
      right: 0,
      child: Center(
        child: InkWell(
          key: const Key('jump-latest'),
          borderRadius: BorderRadius.circular(999),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            decoration: BoxDecoration(
              color: s.bgCard,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: UepColors.gold.withValues(alpha: .35)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: .45),
                  blurRadius: 30,
                  offset: const Offset(0, 12),
                ),
              ],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  unread > 0
                      ? l10n.chatNewMessages(unread)
                      : l10n.chatJumpLatest,
                  style: UepText.mono(
                    size: 10.5,
                    color: UepColors.gold,
                    letterSpacing: 1.2,
                  ),
                ),
                const SizedBox(width: 8),
                const Text(
                  '↓',
                  style: TextStyle(fontSize: 11, color: UepColors.gold),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
