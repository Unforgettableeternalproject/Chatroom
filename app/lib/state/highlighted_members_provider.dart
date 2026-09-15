import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_providers.dart';

/// 被我標記的成員（依房間分開）。
///
/// **純本機視圖**——不送 Hub、不影響任何人看到的內容。與側欄的「隱藏成員」
/// 是同一類東西、方向相反：隱藏是「別讓他佔位置」，標記是「別讓我漏看他」。
///
/// 為什麼是 provider 而不是像隱藏那樣的 widget state：標記要同時影響**側欄**
/// 與**時間軸**，而那是兩個沒有共同祖先的 widget。隱藏只影響側欄自己，
/// 留在 local state 就夠。
///
/// 非 family 的 Notifier、內容是 roomId → ids 的 map：Riverpod 3 的 family
/// Notifier API 與 3.0 之前差異大，為了一個純本機偏好不值得押在上面。
class HighlightedMembers extends Notifier<Map<String, Set<String>>> {
  @override
  Map<String, Set<String>> build() => const {};

  /// 從本機設定讀進來。**冪等**：已經載過的房間不重讀，否則每次 build
  /// 都會把使用者剛按下的變更蓋回去。
  void ensureLoaded(String roomId) {
    if (state.containsKey(roomId)) return;
    final ids = ref.read(settingsRepoProvider).highlightedMembers(roomId);
    state = {...state, roomId: ids};
  }

  Set<String> of(String roomId) => state[roomId] ?? const {};

  Future<void> toggle(String roomId, String participantId) async {
    final next = {...of(roomId)};
    if (!next.remove(participantId)) next.add(participantId);
    state = {...state, roomId: next};
    await ref.read(settingsRepoProvider).setHighlightedMembers(roomId, next);
  }
}

final highlightedMembersProvider =
    NotifierProvider<HighlightedMembers, Map<String, Set<String>>>(
        HighlightedMembers.new);
