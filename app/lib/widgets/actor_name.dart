import 'package:flutter/material.dart';

import '../core/theme/uep_theme.dart';
import '../core/theme/uep_tokens.dart';
import '../models/board.dart';
import 'kind_badge.dart';

/// Board 上一個 actor 的名字，帶別名提示。
///
/// v2 起 Board 的身分是 `actor_key`，不是名字。同一個 agent 掛在多間房時
/// 可能有不同的顯示名（需求房叫「Novia」、實作房叫「開發Novia (UI)」），
/// [BoardActorRef.displayName] 依約定取**最早進入 Board** 的那個。
///
/// 那個約定會製造一個具體的困惑：看板的人在別的房裡認識的是另一個名字，
/// 而板上寫著他沒見過的名字，中間沒有任何線索。這個元件就是那條線索——
/// 別名連同**它來自哪一間房**一起顯示，只有名字的話講不出這件事。
///
/// 用 [Tooltip] 而不是自繪浮層：桌機是 hover、觸控是長按，Flutter 已經
/// 兩邊都處理好了。自己做等於要把長按那半重寫一次，而那半只有在行動端
/// 才看得到——最容易漏掉的一半。
class ActorName extends StatelessWidget {
  const ActorName({
    super.key,
    required this.actor,
    this.size = 11,
    this.color,
    this.showKind = false,
    this.roomNameOf,
  });

  final BoardActorRef actor;
  final double size;
  final Color? color;

  /// 一併顯示種類徽章（human／claude／codex）。
  final bool showKind;

  /// room_id → 房名。**只是備援**：alias 自己帶 `room_name` 快照，
  /// 那份才是權威（房刪掉之後只剩它講得出出處）。
  ///
  /// 這條留著是為了遷移期間——舊 Hub 的 alias 沒有 `room_name`，
  /// 而掛接中的房仍可從 delta 的 `attached_rooms` 查到名字。兩邊都沒有時
  /// 就不講出處：**uuid 對使用者沒有意義**，吐出來只會像資料壞了。
  final String? Function(String roomId)? roomNameOf;

  /// 提示要講的話。沒有別名時回 null——**沒有別名就不要掛空 tooltip**，
  /// 一個 hover 上去什麼都沒有的元件比沒有 hover 更讓人以為壞了。
  String? get _tip {
    if (actor.aliases.isEmpty) return null;
    final lines = actor.aliases.map((a) {
      final room = a.roomName.isNotEmpty
          ? a.roomName
          : (a.roomId.isEmpty ? null : roomNameOf?.call(a.roomId));
      return room == null ? '· ${a.name}' : '· ${a.name}（在「$room」）';
    });
    return '這個人在別的地方叫：\n${lines.join('\n')}';
  }

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    final name = actor.displayName.isEmpty ? '（未命名）' : actor.displayName;

    final label = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (showKind) ...[
          KindBadge(kind: actor.actorKind, compact: true),
          const SizedBox(width: 4),
        ],
        Flexible(
          child: Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: UepText.sans(size: size, color: color ?? s.inkSoft),
          ),
        ),
        // 有別名時給一個看得見的記號。沒有它，別人不會知道這裡可以 hover
        // ——一個沒有人發現的提示等於不存在
        if (actor.aliases.isNotEmpty) ...[
          const SizedBox(width: 3),
          Text('˙',
              style: UepText.mono(
                  size: size, color: (color ?? s.inkSoft).withValues(alpha: .6))),
        ],
      ],
    );

    final tip = _tip;
    if (tip == null) return label;
    return Tooltip(message: tip, child: label);
  }
}

/// [ActorName] 的提示文字。**抽出來只為了讓測試測得到它本人**——
/// 把它留在 build 裡的話，只能靠打開一個 tooltip 再去讀畫面上的字，
/// 而那種測試在講的是 Flutter 的 Tooltip 而不是這裡的規則。
String? actorAliasTooltip(
  BoardActorRef actor, {
  String? Function(String roomId)? roomNameOf,
}) =>
    ActorName(actor: actor, roomNameOf: roomNameOf)._tip;
