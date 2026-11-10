import '../models/message.dart';

/// 慶祝觸發的純判斷與節流，不碰 Flutter、音效或 provider，方便單測。

/// 事件發生後超過這段時間才到的，視為補訊／重連重放而不是「剛剛發生」。
const kCelebrationFreshWindow = Duration(seconds: 45);

/// 兩次慶祝之間的最短間隔；期間內的事件直接合併掉。
const kCelebrationMinGap = Duration(milliseconds: 2500);

/// [message] 這則即時到達的 system 訊息，該不該慶祝。
///
/// - [enabled]：慶祝模式開關。
/// - [roomIsOps]：所在房是否為派工房（`Room.isOps`）；`run_done` 只在派工房算。
/// - [now]：注入時鐘，測試用。
///
/// 「即時」的第一道把關在 NotificationCenter（首批快照與補投不會送來），
/// 這裡的時間窗是第二道：WS 重連用 after_seq 補推的離線訊息對 feed 來說
/// 也是增量，只能靠訊息時間分辨。時間無法解析時一律不慶祝。
bool shouldCelebrate(
  Message message, {
  required bool enabled,
  required bool roomIsOps,
  DateTime? now,
}) {
  if (!enabled) return false;
  if (message.deleted || !message.isSystem) return false;
  switch (message.systemEvent) {
    case 'join':
    case 'board_task_done':
      break;
    case 'run_done':
      if (!roomIsOps) return false;
    default:
      return false;
  }
  final created = DateTime.tryParse(message.createdAt);
  if (created == null) return false;
  final age = (now ?? DateTime.now()).difference(created);
  return age <= kCelebrationFreshWindow;
}

/// 固定間隔節流：間隔內的事件丟棄，不排隊補放。
class CelebrationThrottle {
  CelebrationThrottle({
    this.minGap = kCelebrationMinGap,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final Duration minGap;
  final DateTime Function() _clock;
  DateTime? _last;

  /// 可以放就記下時間並回 true。
  bool tryAcquire() {
    final now = _clock();
    final last = _last;
    if (last != null && now.difference(last) < minGap) return false;
    _last = now;
    return true;
  }
}
