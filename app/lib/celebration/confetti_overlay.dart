import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme/uep_tokens.dart';
import 'celebration_controller.dart';

/// 單片彩紙。位置由 [ConfettiPainter] 依進度解析式算出，不逐幀累加。
class ConfettiParticle {
  const ConfettiParticle({
    required this.originX,
    required this.angle,
    required this.speed,
    required this.spin,
    required this.phase,
    required this.width,
    required this.height,
    required this.color,
  });

  /// 起點在畫面寬度的比例（底邊）。
  final double originX;

  /// 噴射方向（弧度，-pi/2 為正上方）。
  final double angle;

  /// 初速（乘上畫面高度，單位：高度／秒）。
  final double speed;
  final double spin;
  final double phase;
  final double width;
  final double height;
  final Color color;
}

const kConfettiDuration = Duration(milliseconds: 2200);

const _palette = [
  UepColors.gold,
  UepColors.goldSoft,
  UepColors.success,
  UepColors.info,
  UepColors.error,
  UepColors.kindOther,
];

/// 左右下角各噴一束，斜向中央。
List<ConfettiParticle> buildConfettiParticles(
  math.Random rng, {
  int perSide = 36,
}) {
  final out = <ConfettiParticle>[];
  for (final side in const [0, 1]) {
    // 左束朝右上、右束朝左上，各自扇形約 ±18 度
    final center = side == 0 ? -math.pi / 2 + 0.38 : -math.pi / 2 - 0.38;
    for (var i = 0; i < perSide; i++) {
      out.add(
        ConfettiParticle(
          originX: side == 0
              ? 0.12 + rng.nextDouble() * 0.06
              : 0.82 + rng.nextDouble() * 0.06,
          angle: center + (rng.nextDouble() - 0.5) * 0.63,
          speed: 0.75 + rng.nextDouble() * 0.55,
          spin: (rng.nextDouble() - 0.5) * 18,
          phase: rng.nextDouble() * math.pi * 2,
          width: 5 + rng.nextDouble() * 5,
          height: 8 + rng.nextDouble() * 6,
          color: _palette[rng.nextInt(_palette.length)],
        ),
      );
    }
  }
  return out;
}

class ConfettiPainter extends CustomPainter {
  ConfettiPainter(this.particles, this.progress);

  final List<ConfettiParticle> particles;

  /// 0..1。
  final double progress;

  static const _gravity = 1.6; // 畫面高度／秒²

  @override
  void paint(Canvas canvas, Size size) {
    final t = progress * kConfettiDuration.inMilliseconds / 1000.0;
    // 最後 35% 淡出
    final alpha = progress < .65 ? 1.0 : (1 - (progress - .65) / .35);
    if (alpha <= 0) return;
    final paint = Paint();
    for (final p in particles) {
      final x =
          size.width * p.originX +
          math.cos(p.angle) * p.speed * size.height * t +
          math.sin(t * 5 + p.phase) * 6; // 左右飄
      final y =
          size.height +
          math.sin(p.angle) * p.speed * size.height * t +
          0.5 * _gravity * size.height * t * t;
      if (y > size.height + 20) continue;
      paint.color = p.color.withValues(alpha: alpha.clamp(0.0, 1.0));
      canvas.save();
      canvas.translate(x, y);
      canvas.rotate(p.spin * t + p.phase);
      // 以寬度縮放模擬翻面
      final flip = math.cos(t * 7 + p.phase).abs().clamp(0.25, 1.0);
      canvas.drawRect(
        Rect.fromCenter(
          center: Offset.zero,
          width: p.width * flip,
          height: p.height,
        ),
        paint,
      );
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(ConfettiPainter old) =>
      old.progress != progress || old.particles != particles;
}

/// 全畫面彩花層。不吃觸控；沒有進行中的噴發時不繪製。
class CelebrationOverlay extends ConsumerStatefulWidget {
  const CelebrationOverlay({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<CelebrationOverlay> createState() => _CelebrationOverlayState();
}

class _CelebrationOverlayState extends ConsumerState<CelebrationOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _anim = AnimationController(
    vsync: this,
    duration: kConfettiDuration,
  );
  final _rng = math.Random();
  List<ConfettiParticle> _particles = const [];
  StreamSubscription<void>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = ref
        .read(celebrationControllerProvider)
        .bursts
        .listen((_) => _burst());
  }

  void _burst() {
    if (!mounted) return;
    _particles = buildConfettiParticles(_rng);
    _anim.forward(from: 0);
  }

  @override
  void dispose() {
    _sub?.cancel();
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      textDirection: TextDirection.ltr,
      children: [
        Positioned.fill(child: widget.child),
        Positioned.fill(
          child: IgnorePointer(
            child: AnimatedBuilder(
              animation: _anim,
              builder: (context, _) => _anim.isAnimating
                  ? RepaintBoundary(
                      child: CustomPaint(
                        painter: ConfettiPainter(_particles, _anim.value),
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
          ),
        ),
      ],
    );
  }
}
