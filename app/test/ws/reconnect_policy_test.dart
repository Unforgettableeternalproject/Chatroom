import 'dart:math';

import 'package:chatroom_app/ws/reconnect_policy.dart';
import 'package:flutter_test/flutter_test.dart';

/// 固定亂數：nextDouble 永遠 0.5 → jitter 抵銷，得到未擾動的序列。
class _FixedRandom implements Random {
  @override
  bool nextBool() => false;

  @override
  double nextDouble() => 0.5;

  @override
  int nextInt(int max) => 0;
}

void main() {
  group('ReconnectPolicy', () {
    final policy = ReconnectPolicy(rng: _FixedRandom());

    test('退避序列 0.3s → 0.6s → 1.2s → …', () {
      expect(policy.delayFor(0).inMilliseconds, 300);
      expect(policy.delayFor(1).inMilliseconds, 600);
      expect(policy.delayFor(2).inMilliseconds, 1200);
      expect(policy.delayFor(3).inMilliseconds, 2400);
    });

    test('封頂 30 秒', () {
      expect(policy.delayFor(10).inMilliseconds, 30000);
      expect(policy.delayFor(100).inMilliseconds, 30000);
    });

    test('jitter 在 ±25% 範圍內', () {
      final real = ReconnectPolicy();
      for (var i = 0; i < 50; i++) {
        final d = real.delayFor(2).inMilliseconds; // base 1200
        expect(d, inInclusiveRange(900, 1500));
      }
    });
  });
}
