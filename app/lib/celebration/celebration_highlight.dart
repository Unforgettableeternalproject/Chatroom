import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme/uep_tokens.dart';
import 'confetti_overlay.dart';

/// 標示的有效窗口：超過這段時間才建出來的 tile（例如捲回來）不再播。
const kCelebrationHighlightWindow = Duration(milliseconds: 2500);

/// 哪些 message id 剛觸發過慶祝、哪些已經播過。
///
/// 一次性：[consume] 每個 id 只會成功一次，捲動重建 widget 不會重播。
/// 只有真正通過節流的慶祝才會 [mark]。
class CelebrationHighlights extends Notifier<Map<String, DateTime>> {
  final Set<String> _played = {};
  DateTime Function() clock = DateTime.now;

  @override
  Map<String, DateTime> build() => const {};

  void mark(String messageId) {
    if (_played.contains(messageId)) return;
    state = {...state, messageId: clock()};
  }

  /// 這個 id 現在該播嗎。該播就同時記為已播。
  bool consume(String messageId) {
    final at = state[messageId];
    if (at == null || _played.contains(messageId)) return false;
    if (clock().difference(at) > kCelebrationHighlightWindow) return false;
    _played.add(messageId);
    return true;
  }
}

final celebrationHighlightsProvider =
    NotifierProvider<CelebrationHighlights, Map<String, DateTime>>(
      CelebrationHighlights.new,
    );

/// 包住一則 system 訊息；被 mark 過且還在窗口內就播一次標示。
class CelebrationHighlight extends ConsumerStatefulWidget {
  const CelebrationHighlight({
    super.key,
    required this.messageId,
    required this.child,
  });

  final String messageId;
  final Widget child;

  @override
  ConsumerState<CelebrationHighlight> createState() =>
      _CelebrationHighlightState();
}

class _CelebrationHighlightState extends ConsumerState<CelebrationHighlight>
    with SingleTickerProviderStateMixin {
  late final AnimationController _anim = AnimationController(
    vsync: this,
    duration: kConfettiDuration,
  );

  @override
  void initState() {
    super.initState();
    // tile 晚於 mark 才建出來（feed 先更新、慶祝後到）
    _tryPlay();
  }

  void _tryPlay() {
    if (ref
        .read(celebrationHighlightsProvider.notifier)
        .consume(widget.messageId)) {
      _anim.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // tile 早於 mark 就在畫面上
    ref.listen(celebrationHighlightsProvider, (_, next) {
      if (next.containsKey(widget.messageId)) _tryPlay();
    });
    return CelebrationGlowScope(animation: _anim, child: widget.child);
  }
}

/// 把呼吸動畫往下傳給 [CelebrationGlowText]。
class CelebrationGlowScope extends InheritedWidget {
  const CelebrationGlowScope({
    super.key,
    required this.animation,
    required super.child,
  });

  final Animation<double> animation;

  @override
  bool updateShouldNotify(CelebrationGlowScope old) =>
      old.animation != animation;
}

/// system 訊息的文字。在 [CelebrationHighlight] 播放期間，
/// 文字顏色與發光在原色與金色間脈動一次；其餘時候就是普通 [Text]。
class CelebrationGlowText extends StatelessWidget {
  const CelebrationGlowText(
    this.data, {
    super.key,
    required this.style,
    this.textAlign,
  });

  final String data;
  final TextStyle style;
  final TextAlign? textAlign;

  @override
  Widget build(BuildContext context) {
    final anim = context
        .dependOnInheritedWidgetOfExactType<CelebrationGlowScope>()
        ?.animation;
    if (anim == null) return Text(data, style: style, textAlign: textAlign);
    return AnimatedBuilder(
      animation: anim,
      builder: (context, _) {
        if (!anim.isAnimating) {
          return Text(data, style: style, textAlign: textAlign);
        }
        // 淡入到 1 再淡出，一個完整呼吸
        final k = math.sin(anim.value * math.pi);
        return Text(
          data,
          textAlign: textAlign,
          style: style.copyWith(
            color: Color.lerp(style.color, UepColors.gold, k),
            shadows: [
              Shadow(
                color: UepColors.gold.withValues(alpha: .7 * k),
                blurRadius: 10 * k,
              ),
            ],
          ),
        );
      },
    );
  }
}
