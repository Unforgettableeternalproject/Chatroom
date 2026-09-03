import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/scratchpad_api.dart';
import '../models/scratchpad.dart';
import 'app_providers.dart';

final scratchpadApiProvider = Provider<ScratchpadApi>(
  (ref) => ScratchpadApi(ref.watch(dioProvider)),
);

final watchApiProvider = Provider<WatchApi>(
  (ref) => WatchApi(ref.watch(dioProvider)),
);

/// 一塊板上的想法板清單。
final scratchpadListProvider =
    FutureProvider.family<List<ScratchpadSummary>, String>((ref, boardId) {
  final key = ref.watch(appConfigProvider).deviceKey;
  return ref.watch(scratchpadApiProvider).list(boardId, sessionKey: key);
});

/// 一份想法板的全文。
///
/// ⚠️ key 用 `boardId/padId` 併起來：只用 padId 的話，同一份板在兩塊板底下
/// （理論上不會，但 provider 不該假設）會共用同一格快取。
final scratchpadProvider =
    FutureProvider.family<Scratchpad, String>((ref, key) {
  final parts = key.split('/');
  final sessionKey = ref.watch(appConfigProvider).deviceKey;
  return ref
      .watch(scratchpadApiProvider)
      .fetch(parts[0], parts[1], sessionKey: sessionKey);
});

String scratchpadKey(String boardId, String padId) => '$boardId/$padId';

/// 我的追蹤收件匣。**跨板**。
///
/// 這個 provider 是那顆紅點唯一的來源。裁決 #392 ②A 是「離線通知留著，
/// 回來就知道」——**知道的管道就是它**，少了它，通知留著了但沒有任何
/// 地方會告訴人有東西留著。
final watchNoticesProvider =
    FutureProvider<({List<WatchNotice> notices, int unread})>((ref) {
  final key = ref.watch(appConfigProvider).deviceKey;
  // ⚠️ **要已讀的也拿回來**（`unreadOnly: false`）。只拿未讀的話，點開一筆
  // 標記已讀之後它會從清單上**消失**——而人剛剛才在那裡看到它，會懷疑
  // 自己是不是看錯了。讀過的該留著、只是不再喊
  // （@審核用Codex-2 2026-09-03；我自己在 _NoticeRow 的註解裡寫了這條規則，
  //  卻在這一行做了相反的事）。
  //
  // 紅點的數字不受影響：Hub 的 `unread_count` 是獨立算的，不跟著這個
  // 篩選走，所以拿全部回來不會讓那個數字變大。
  return ref.watch(watchApiProvider).notices(sessionKey: key, unreadOnly: false);
});

/// 每一塊板各有幾筆未讀。
///
/// Hub 沒有 per-board 的 `unread_notice_count`，但收件匣每一筆都帶 `board_id`
/// ——**一次呼叫就能算出全部**，比一塊板打一支 API 便宜，也不會有某塊板
/// 忘了打的問題。
Map<String, int> unreadByBoard(List<WatchNotice> notices) {
  final out = <String, int>{};
  for (final n in notices) {
    if (!n.unread || n.boardId.isEmpty) continue;
    out[n.boardId] = (out[n.boardId] ?? 0) + 1;
  }
  return out;
}
