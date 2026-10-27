import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';

/// 啟動時要等的一項初始化工作。
typedef StartupInitializer = Future<void> Function();

/// 啟動 Loading 至少停留的時間。
const Duration kStartupMinDuration = Duration(seconds: 2);

/// 初始化遲遲不完成時的放行上限——Loading 不能把人永遠擋在門外。
const Duration kStartupMaxWait = Duration(seconds: 15);

/// 初始化掛點。之後需要延遲載入的功能把工作加進這份清單，Loading 會等
/// 它們全部完成（或失敗）才離開。目前是空的。
///
/// 加法：在 ProviderScope 的 override 或這裡直接回傳
/// `[() => ref.read(xxxProvider).warmUp()]`。測試用 override 換成空清單。
final startupInitializersProvider = Provider<List<StartupInitializer>>(
  (ref) => const [],
);

/// 最短停留時間。測試 override 成 [Duration.zero] 即可略過等待。
final startupMinDurationProvider = Provider<Duration>(
  (ref) => kStartupMinDuration,
);

/// 一次啟動閘的結果。
class StartupGateResult {
  const StartupGateResult({this.errors = const [], this.timedOut = false});

  /// 丟錯的初始化工作（已記 log，不阻擋進入 App）。
  final List<Object> errors;

  /// 是否因超過 [kStartupMaxWait] 而放行。
  final bool timedOut;
}

/// 啟動閘：離開時間 = max(最短停留, 全部初始化完成)。
///
/// 初始化丟錯（含同步丟錯）只記 log 並照常放行——這些工作是「讓 App 更快」
/// 的預載，不是進入 App 的前提，卡在 Loading 比缺一份預載更糟。
/// 超過 [maxWait] 仍未完成也放行。
class StartupGate {
  StartupGate({
    required this.initializers,
    this.minDuration = kStartupMinDuration,
    this.maxWait = kStartupMaxWait,
  });

  final List<StartupInitializer> initializers;
  final Duration minDuration;
  final Duration maxWait;

  static final _log = Logger('startup');

  final _done = Completer<StartupGateResult>();
  final _errors = <Object>[];
  Timer? _minTimer;
  Timer? _maxTimer;
  bool _minElapsed = false;
  int _pending = 0;
  bool _started = false;

  /// 開始計時並啟動所有初始化工作。只能呼叫一次。
  Future<StartupGateResult> run() {
    if (_started) return _done.future;
    _started = true;
    _pending = initializers.length;
    _minTimer = Timer(minDuration, () {
      _minElapsed = true;
      _maybeFinish();
    });
    // 上限必須比最短停留長，否則「至少 N 秒」會被它破壞
    final cap = maxWait < minDuration ? minDuration : maxWait;
    _maxTimer = Timer(cap, () => _finish(timedOut: true));
    for (final init in initializers) {
      _runOne(init);
    }
    _maybeFinish();
    return _done.future;
  }

  Future<void> _runOne(StartupInitializer init) async {
    try {
      await init();
    } catch (e, st) {
      _errors.add(e);
      _log.warning('啟動初始化失敗，略過並繼續進入 App：$e', e, st);
    } finally {
      _pending--;
      _maybeFinish();
    }
  }

  void _maybeFinish() {
    if (_minElapsed && _pending <= 0) _finish();
  }

  void _finish({bool timedOut = false}) {
    if (_done.isCompleted) return;
    _minTimer?.cancel();
    _maxTimer?.cancel();
    _done.complete(
      StartupGateResult(errors: List.unmodifiable(_errors), timedOut: timedOut),
    );
  }

  /// 畫面先被拆掉時呼叫：取消計時器，避免留下孤兒 timer。
  void cancel() {
    _minTimer?.cancel();
    _maxTimer?.cancel();
  }
}
