import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 送出過的訊息，**依房間分開**——輸入框的上下鍵歷史就靠它。
///
/// ## 為什麼不放在 `_MessageComposerState` 裡
///
/// 與 [ComposerDrafts] 同一個病因的第四次現身：切換房間時
/// `ValueKey(roomId)` 讓 `ChatScreen` 的 State 整顆重建，任何存在 State
/// 裡的東西都會跟著消失。草稿踩過三次（切房跑到別房、`ListView` 回收、
/// 答題卡被回收），歷史是同一個形狀——切走再切回來，剛剛送出的十則就
/// 全部不見，而它不會報錯，只是上鍵按下去沒有反應。
///
/// ## 只在記憶體
///
/// 不寫本機設定。理由同草稿：這是「這一輪講過的話」，關掉 App 之後多半
/// 已經不成立。真的需要跨啟動保留時再加，不要預先做。
class ComposerHistory extends Notifier<Map<String, List<String>>> {
  /// 每房保留幾則。終端機的 history 也有上限，理由一樣：再往上翻的東西
  /// 沒有人找得到，只是讓記憶體隨著聊天無上限成長。
  static const maxPerRoom = 50;

  @override
  Map<String, List<String>> build() => const {};

  /// 由舊到新。空清單代表這個房間還沒說過話。
  List<String> of(String roomId) => state[roomId] ?? const [];

  /// 送出成功之後叫它。
  ///
  /// **連續重複的內容不重複記**（比照 bash 的 `ignoredups`）——同一句話按
  /// 兩次送出，上鍵要按兩下才回到前一則，那個行為沒有人預期得到。
  void add(String roomId, String content) {
    if (content.isEmpty) return;
    final current = of(roomId);
    if (current.isNotEmpty && current.last == content) return;
    final next = [...current, content];
    if (next.length > maxPerRoom) {
      next.removeRange(0, next.length - maxPerRoom);
    }
    state = {...state, roomId: next};
  }
}

final composerHistoryProvider =
    NotifierProvider<ComposerHistory, Map<String, List<String>>>(
        ComposerHistory.new);
