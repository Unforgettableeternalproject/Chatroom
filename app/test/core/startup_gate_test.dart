// ignore: depend_on_referenced_packages
import 'package:fake_async/fake_async.dart';
import 'dart:async';
import 'dart:math';

import 'package:chatroom_app/core/startup/splash_text.dart';
import 'package:chatroom_app/core/startup/startup_gate.dart';
import 'package:flutter_test/flutter_test.dart';

/// 啟動閘：離開時間 = max(最短停留, 初始化完成)；丟錯與卡死都不能擋人。
void main() {
  /// 跑一個閘，回傳「放行發生在第幾毫秒」。
  int? runAndMeasure(
    FakeAsync async,
    StartupGate gate, {
    int stepMs = 100,
    int totalMs = 20000,
    void Function(StartupGateResult r)? onResult,
  }) {
    int? doneAt;
    var now = 0;
    gate.run().then((r) {
      doneAt = async.elapsed.inMilliseconds;
      onResult?.call(r);
    });
    while (now < totalMs && doneAt == null) {
      async.elapse(Duration(milliseconds: stepMs));
      now += stepMs;
    }
    return doneAt;
  }

  test('初始化 0.5 秒 → 等滿 2 秒才離開', () {
    fakeAsync((async) {
      final gate = StartupGate(initializers: [
        () => Future<void>.delayed(const Duration(milliseconds: 500)),
      ]);
      expect(runAndMeasure(async, gate), 2000);
    });
  });

  test('初始化 3 秒 → 3 秒離開', () {
    fakeAsync((async) {
      final gate = StartupGate(initializers: [
        () => Future<void>.delayed(const Duration(seconds: 3)),
      ]);
      expect(runAndMeasure(async, gate), 3000);
    });
  });

  test('沒有初始化工作 → 2 秒離開', () {
    fakeAsync((async) {
      final gate = StartupGate(initializers: const []);
      expect(runAndMeasure(async, gate), 2000);
    });
  });

  test('多項初始化以最慢那項為準', () {
    fakeAsync((async) {
      final gate = StartupGate(initializers: [
        () => Future<void>.delayed(const Duration(milliseconds: 300)),
        () => Future<void>.delayed(const Duration(milliseconds: 2500)),
      ]);
      expect(runAndMeasure(async, gate), 2500);
    });
  });

  test('初始化丟錯 → 不卡住，記入結果，仍等滿最短停留', () {
    fakeAsync((async) {
      final gate = StartupGate(initializers: [
        () async => throw StateError('壞了'),
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      ]);
      StartupGateResult? result;
      final at = runAndMeasure(async, gate, onResult: (r) => result = r);
      expect(at, 2000);
      expect(result!.errors, hasLength(1));
      expect(result!.timedOut, isFalse);
    });
  });

  test('初始化同步丟錯也一樣放行', () {
    fakeAsync((async) {
      final gate = StartupGate(initializers: [
        () => throw StateError('同步壞掉'),
      ]);
      StartupGateResult? result;
      expect(runAndMeasure(async, gate, onResult: (r) => result = r), 2000);
      expect(result!.errors, hasLength(1));
    });
  });

  test('初始化永不完成 → 超過上限放行', () {
    fakeAsync((async) {
      final gate = StartupGate(
        initializers: [() => Completer<void>().future],
        maxWait: const Duration(seconds: 10),
      );
      StartupGateResult? result;
      expect(runAndMeasure(async, gate, onResult: (r) => result = r), 10000);
      expect(result!.timedOut, isTrue);
    });
  });

  test('上限不會把最短停留縮短', () {
    fakeAsync((async) {
      final gate = StartupGate(
        initializers: const [],
        minDuration: const Duration(seconds: 5),
        maxWait: const Duration(seconds: 1),
      );
      expect(runAndMeasure(async, gate), 5000);
    });
  });

  test('cancel 後不再有待處理的 timer', () {
    fakeAsync((async) {
      final gate = StartupGate(initializers: const []);
      gate.run();
      gate.cancel();
      expect(async.pendingTimers, isEmpty);
    });
  });

  group('pickSplashText', () {
    const fallback = '預設';

    test('空值或只有空白 → 預設', () {
      expect(pickSplashText('', fallback: fallback), fallback);
      expect(pickSplashText('  \n \r\n\t', fallback: fallback), fallback);
    });

    test('單行 → 固定，去頭尾空白', () {
      expect(pickSplashText('  你好  ', fallback: fallback), '你好');
    });

    test('多行 → 只會挑到有內容的候選（略過空行）', () {
      final seen = <String>{};
      final rng = Random(7);
      for (var i = 0; i < 200; i++) {
        seen.add(pickSplashText('甲\n\n乙\r\n 丙 \n',
            fallback: fallback, random: rng));
      }
      expect(seen, {'甲', '乙', '丙'});
    });

    test('隨機索引決定結果（可注入 Random）', () {
      expect(splashCandidates('a\nb\nc'), ['a', 'b', 'c']);
      expect(pickSplashText('a\nb\nc', fallback: fallback, random: _Fixed(2)),
          'c');
    });
  });
}

class _Fixed implements Random {
  _Fixed(this.v);
  final int v;
  @override
  int nextInt(int max) => v;
  @override
  bool nextBool() => false;
  @override
  double nextDouble() => 0;
}
