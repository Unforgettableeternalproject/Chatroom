import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/startup/splash_text.dart';
import '../../core/startup/startup_gate.dart';
import '../../core/theme/uep_theme.dart';
import '../../core/theme/uep_tokens.dart';
import '../../l10n/app_localizations.dart';
import '../../state/app_providers.dart';

/// 啟動 Loading：蓋在 App 之上，等 [StartupGate] 放行才淡出。
///
/// [child]（App 本體）照常在底下建構——既有的啟動邏輯（Hub 連線、首次設定
/// 的 redirect）不因 Loading 延後；Loading 只負責擋住畫面與輸入，直到
/// max(最短停留, 初始化完成)。
class StartupSplashGate extends ConsumerStatefulWidget {
  const StartupSplashGate({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<StartupSplashGate> createState() => _StartupSplashGateState();
}

class _StartupSplashGateState extends ConsumerState<StartupSplashGate> {
  late final StartupGate _gate;
  String? _text;
  bool _ready = false;
  // 淡出結束後才真正移除，避免最後一格畫面閃一下
  bool _removed = false;

  @override
  void initState() {
    super.initState();
    _gate = StartupGate(
      initializers: ref.read(startupInitializersProvider),
      minDuration: ref.read(startupMinDurationProvider),
    );
    _gate.run().then((_) {
      if (mounted) setState(() => _ready = true);
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 每次啟動只挑一次；之後換語言或重建都不再換字
    _text ??= pickSplashText(
      ref.read(appConfigProvider).splashText,
      fallback: AppLocalizations.of(context).splashDefaultText,
    );
  }

  @override
  void dispose() {
    _gate.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduce = MediaQuery.disableAnimationsOf(context);
    return Stack(
      fit: StackFit.passthrough,
      children: [
        // 底下的 App 不接受焦點與點擊，Loading 期間不會有看不見的操作
        ExcludeFocus(
          excluding: !_ready,
          child: IgnorePointer(ignoring: !_ready, child: widget.child),
        ),
        // Stack 結構固定：App 本體永遠在同一個位置，Loading 移除時只是這格
        // 變空，不能讓整棵 App 因為換了父層而被重建
        if (_removed || (_ready && reduce))
          const SizedBox.shrink()
        else
          Positioned.fill(
            child: IgnorePointer(
              ignoring: _ready,
              child: AnimatedOpacity(
                opacity: _ready ? 0 : 1,
                duration: reduce
                    ? Duration.zero
                    : const Duration(milliseconds: 240),
                onEnd: () {
                  if (_ready && mounted) setState(() => _removed = true);
                },
                child: StartupSplash(text: _text ?? '', reduceMotion: reduce),
              ),
            ),
          ),
      ],
    );
  }
}

/// Loading 畫面本體：字樣淡入後緩慢呼吸，下方一條細金線同步明滅。
/// [reduceMotion] 時不做任何動畫，直接靜態顯示。
class StartupSplash extends StatefulWidget {
  const StartupSplash({
    super.key,
    required this.text,
    this.reduceMotion = false,
  });

  final String text;
  final bool reduceMotion;

  @override
  State<StartupSplash> createState() => _StartupSplashState();
}

class _StartupSplashState extends State<StartupSplash>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2400),
    );
    if (!widget.reduceMotion) _c.repeat();
  }

  @override
  void didUpdateWidget(StartupSplash old) {
    super.didUpdateWidget(old);
    if (widget.reduceMotion) {
      _c.stop();
    } else if (!_c.isAnimating) {
      _c.repeat();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    return ColoredBox(
      color: s.bg,
      child: Center(
        child: widget.reduceMotion
            ? _content(s, 1, 1)
            : AnimatedBuilder(
                animation: _c,
                builder: (context, _) {
                  // 前 0.35 個週期從 0 淡入，之後在 0.65~1 之間呼吸
                  final t = _c.value;
                  final breathe = 0.82 + 0.18 * math.sin(t * 2 * math.pi);
                  return TweenAnimationBuilder<double>(
                    tween: Tween(begin: 0, end: 1),
                    duration: const Duration(milliseconds: 700),
                    curve: Curves.easeOut,
                    builder: (context, fadeIn, _) =>
                        _content(s, fadeIn, breathe),
                  );
                },
              ),
      ),
    );
  }

  Widget _content(UepSurface s, double fadeIn, double breathe) {
    return Opacity(
      opacity: (fadeIn * breathe).clamp(0.0, 1.0),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              widget.text,
              textAlign: TextAlign.center,
              style: UepText.display(size: 28, color: s.inkTitle),
            ),
            const SizedBox(height: 18),
            Container(
              width: 36,
              height: 2,
              decoration: BoxDecoration(
                color: UepColors.gold,
                borderRadius: BorderRadius.circular(1),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
