import 'dart:math';

/// 指數退避（UI-DESIGN §4.2）。純函式，可完整單元測試。
/// 序列（未加 jitter）：0.3s → 0.6s → 1.2s → … → 30s（封頂），±25% full jitter。
class ReconnectPolicy {
  ReconnectPolicy({Random? rng}) : _rng = rng ?? Random();

  static const baseDelay = Duration(milliseconds: 300);
  static const factor = 2.0;
  static const maxDelay = Duration(seconds: 30);
  static const jitterRatio = 0.25;

  final Random _rng;

  Duration delayFor(int attempt) {
    final rawMs = baseDelay.inMilliseconds * pow(factor, attempt);
    final cappedMs = min(rawMs, maxDelay.inMilliseconds.toDouble());
    final j = cappedMs * jitterRatio;
    final ms = (cappedMs + _rng.nextDouble() * 2 * j - j).round();
    return Duration(milliseconds: max(0, ms));
  }
}
