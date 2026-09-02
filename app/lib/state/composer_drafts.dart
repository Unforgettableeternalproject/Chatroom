import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 還沒送出的字，**依房間分開**。
///
/// ## 為什麼需要它
///
/// 草稿原本活在 `_MessageComposerState` 的 `TextEditingController` 裡，而
/// 切換房間時 route builder 產生的 `ChatScreen` 沒有 key ⇒ Flutter 重用同一
/// 顆 State ⇒ **打到一半的字跟著跑到另一個房間**（艾斯維爾 2026-09-02）。
///
/// 病因不是「草稿沒存」，是**草稿存在一個不屬於任何房間的地方**。
///
/// 修法兩層，缺一不可：
/// 1. `app.dart` 的 route builder 給 `ChatScreen` 一個 `ValueKey(roomId)`
///    ——State 隨房重建，回覆目標與待送附件也跟著不再跨房（那兩樣比字更嚴重：
///    附件會**在別的房被送出去**）
/// 2. 草稿改存在這裡——第 1 層讓 State 重建，若沒有第 2 層，字就從「跑到
///    別的房」變成「直接消失」。那是把問題換一個樣子，對正在打長訊息的人更糟
///
/// ## 只在記憶體
///
/// 不寫本機設定：草稿是「這一輪還沒說完的話」，關掉 App 之後那句話多半
/// 已經不成立了。真的需要跨啟動保留時再加，不要預先做。
class ComposerDrafts extends Notifier<Map<String, String>> {
  @override
  Map<String, String> build() => const {};

  String of(String roomId) => state[roomId] ?? '';

  /// 存草稿。**空字串等於沒有草稿**，直接移除那一格——留著空字串會讓
  /// `state` 隨著逛過的房間無上限成長，而那些格子沒有任何用處。
  void set(String roomId, String text) {
    if (text.isEmpty) {
      if (!state.containsKey(roomId)) return;
      final next = {...state}..remove(roomId);
      state = next;
      return;
    }
    if (state[roomId] == text) return;
    state = {...state, roomId: text};
  }

  /// 送出成功之後叫它。**清掉的是那一房**，不是全部。
  void clear(String roomId) => set(roomId, '');
}

final composerDraftsProvider =
    NotifierProvider<ComposerDrafts, Map<String, String>>(ComposerDrafts.new);
