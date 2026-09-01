import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/theme/uep_theme.dart';
import '../core/theme/uep_tokens.dart';
import '../core/util/relative_time.dart';
import '../models/message.dart';
import 'attachment_view.dart';
import 'kind_badge.dart';
import 'markdown_body.dart';

/// 訊息操作回呼（由 ChatScreen 提供實作）。
class MessageActions {
  const MessageActions({
    required this.onReply,
    required this.onTogglePin,
    required this.onDelete,
    required this.onEdit,
    required this.onCreateTask,
    this.enabled = true,
  });

  final void Function(Message) onReply;
  final void Function(Message) onTogglePin;
  final void Function(Message) onDelete;

  /// 編輯**只有發送者本人做得到**（Hub 端也這樣驗）——刪除是破壞、看得
  /// 出來，編輯是改了看不出來，所以建立者管得了刪除卻管不了這個。
  final void Function(Message) onEdit;

  /// 從這則訊息長出一張 Task。
  ///
  /// **這是 App 上唯一產得出 `source_seq` 的路徑**：board 畫面上建的卡沒有
  /// 來源訊息可指，而一張卡最後總會變成一句沒有上下文的話。決定它的討論
  /// 還在聊天室裡，那個 seq 就是回去的路。
  final void Function(Message) onCreateTask;

  /// 封存房間：釘選 / 刪除 / 回覆停用（P3-08 條件 4）。
  final bool enabled;
}

/// A 標準氣泡（設計稿定案變體）：左側 kind 色軸 + 卡片氣泡。
/// 自己的訊息靠右、金色系、無色軸。
class MessageBubble extends StatelessWidget {
  const MessageBubble({
    super.key,
    required this.message,
    required this.isSelf,
    required this.senderKind,
    this.actions,
    this.highlighted = false,
    this.memberHighlighted = false,
    this.serverUrl = '',
    this.token = '',
    this.participantId,
    this.subagentOf,
  });

  final Message message;

  /// 附件要直接向 Hub 取圖，因此需要位址與 token。空字串時附件只顯示檔名。
  final String serverUrl;
  final String token;

  /// 房內身分；附件下載也在讀取邊界內。
  final String? participantId;
  final bool isSelf;
  final String senderKind;
  final MessageActions? actions;

  /// 發話者是誰旗下的子代理（父層名字）；一般成員為 null。
  /// 子代理不是獨立的人，看到它說話卻不知道是誰派的，就無從判斷該不該信、
  /// 該回給誰。
  final String? subagentOf;

  /// focusSeq 跳轉的高亮。**暫態**，跳完就消失。
  final bool highlighted;

  /// 這個發話者被我標記為重點——**常駐**，直到我取消標記。
  ///
  /// 刻意與 [highlighted] 分成兩個參數而不是共用一個：一個是暫態、一個是
  /// 常駐，共用會讓「我剛跳轉到這則」與「這個人我在等」互相覆蓋，而且金色
  /// 已經被 self / pinned / focus 三種狀態占滿了。這裡用發話者自己的
  /// kind 色做整圈邊框 + 淡底 + 加粗左軸——在同一套色系裡加重，不新增
  /// 一種顏色語彙。（只加粗左軸的版本被推翻過：訊息一多根本看不出 2px
  /// 與 5px 的差別，強調到看不出來等於沒有強調。）
  final bool memberHighlighted;

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    final color = kindColor(senderKind, context: context);
    final name = message.senderName ?? '（未知）';
    final time = clockTime(message.createdAt);
    final isSub = subagentOf != null;

    final header = Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        if (isSelf) ...[
          Text(time, style: UepText.mono(size: 9, color: s.inkMute)),
          const SizedBox(width: 8),
          KindBadge(kind: senderKind),
          const SizedBox(width: 8),
          Text(name,
              style: UepText.sans(
                  size: 13, weight: FontWeight.w600, color: s.inkTitle)),
        ] else ...[
          Text(name,
              style: UepText.sans(
                  size: 13,
                  weight: FontWeight.w600,
                  color: message.deleted ? s.inkMute : s.inkTitle)),
          // 成員面板上的標記開關是一顆星，這裡回應同一顆星——兩個畫面
          // 用同一個符號講同一件事
          if (memberHighlighted) ...[
            const SizedBox(width: 6),
            Text('★', style: UepText.sans(size: 10, color: color)),
          ],
          const SizedBox(width: 8),
          KindBadge(kind: senderKind),
          const SizedBox(width: 8),
          Text(time, style: UepText.mono(size: 9, color: s.inkMute)),
          if (isSub) ...[
            const SizedBox(width: 8),
            Text('↳ $subagentOf 的子代理',
                style: UepText.serif(size: 10, color: s.inkMute)),
          ],
          if (message.pinned) ...[
            const SizedBox(width: 8),
            Text('❖ 已釘選',
                style: UepText.mono(
                    size: 9, color: UepColors.gold, letterSpacing: 1.0)),
          ],
          // 編輯與刪除的差別就是「改了看不出來」——不畫這個標記，那條把
          // 建立者擋在編輯之外的界線就在最後一哩失守
          if (message.editedAt != null) ...[
            const SizedBox(width: 8),
            Text('已編輯',
                style: UepText.mono(
                    size: 9, color: s.inkMute, letterSpacing: 1.0)),
          ],
        ],
      ],
    );

    final Widget body;
    if (message.deleted) {
      body = Container(
        padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 9),
        decoration: BoxDecoration(
          border: Border.all(color: s.lineStrong, style: BorderStyle.solid),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text('訊息已刪除',
            style: UepText.mono(size: 11, color: s.inkMute, letterSpacing: .8)),
      );
    } else {
      body = Container(
        padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 11),
        decoration: BoxDecoration(
          color: isSelf
              ? UepColors.gold.withValues(alpha: .10)
              // 子代理的底色更淡：它的話是別人派出去的工作產出，
              // 不該和房內成員自己的發言有同樣的視覺重量
              : isSub
                  ? s.bgCard.withValues(alpha: .55)
                  // 標記成員的淡底：與自己訊息的金色淡底同一套手法，
                  // 換成發話者的 kind 色
                  : memberHighlighted
                      ? Color.alphaBlend(color.withValues(alpha: .07), s.bgCard)
                      : s.bgCard,
          border: Border.all(
            // 優先序：跳轉聚焦（暫態，蓋過一切）> 自己 > 標記成員 > 釘選。
            // 標記壓過釘選是刻意的——釘選在 header 已有「❖ 已釘選」字樣，
            // 邊框讓給「這個人我在等」不會丟資訊
            color: highlighted
                ? UepColors.gold
                : isSelf
                    ? UepColors.gold.withValues(alpha: .28)
                    : memberHighlighted
                        ? color.withValues(alpha: .55)
                        : message.pinned
                            ? UepColors.gold.withValues(alpha: .22)
                            : (isSub ? color.withValues(alpha: .35) : s.line),
            width: memberHighlighted && !isSelf ? 1.4 : (isSub ? 1.2 : 1),
          ),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (message.replyPreview != null) ...[
              _ReplyQuote(preview: message.replyPreview!),
              const SizedBox(height: 9),
            ],
            UepMarkdownBody(data: message.content, mentions: message.mentions),
            // 群組 @ 的訊息，`mentions` 是 Hub 展開後的全房名單——照畫會在
            // 每則 `@all` 底下掛一整排名字。用 `mention_groups`（發話者原本
            // 打的字面）摺疊成一顆 chip。
            //
            // **不用「數量超過 N 就摺疊」那種啟發式**：那會在小房間裡不摺疊、
            // 在大房間裡把正當的個別 @ 也一起吃掉，兩邊都錯。
            if (message.mentionGroups.isNotEmpty) ...[
              const SizedBox(height: 7),
              _PingedRow(
                names: [for (final g in message.mentionGroups) '$g（全體）'],
              ),
            ] else if (unrenderedMentions(message.content, message.mentions)
                case final pinged when pinged.isNotEmpty) ...[
              const SizedBox(height: 7),
              _PingedRow(names: pinged),
            ],
            if (message.attachments.isNotEmpty && serverUrl.isNotEmpty)
              AttachmentView(
                attachments: message.attachments,
                serverUrl: serverUrl,
                token: token,
                participantId: participantId,
              ),
          ],
        ),
      );
    }

    // 標記的成員左軸加粗到 5px，與整圈邊框、淡底一起構成強調。自己的
    // 訊息沒有左軸也不需要標記——不會有人在等自己回話
    final axisWidth = memberHighlighted ? 5.0 : 2.0;
    final bubble = isSelf
        ? body
        : Container(
            decoration: BoxDecoration(
              border: Border(
                left: BorderSide(
                  color: message.deleted ? s.hairline : color,
                  width: axisWidth,
                ),
              ),
            ),
            padding: EdgeInsets.only(left: 14 - axisWidth),
            child: body,
          );

    final column = Column(
      crossAxisAlignment:
          isSelf ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: EdgeInsets.only(left: isSelf ? 0 : 13),
          child: header,
        ),
        const SizedBox(height: 6),
        bubble,
      ],
    );

    return Align(
      alignment: isSelf ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: isSelf ? 620 : 660),
        child: _ContextMenuRegion(
          message: message,
          actions: actions,
          isSelf: isSelf,
          child: column,
        ),
      ),
    );
  }
}

/// 「這則訊息 ping 了誰」——只列正文裡沒寫 `@名字` 的那些。
///
/// agent 走 API 的 mentions 參數時正文通常沒有 `@`，泡泡上因此完全看不出
/// 它 tag 了人。這排 chip 把結構化的 mentions 攤到看得見的地方。
class _PingedRow extends StatelessWidget {
  const _PingedRow({required this.names});

  final List<String> names;

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    return Wrap(
      spacing: 4,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text('提及',
            style: UepText.mono(size: 10.5, color: s.inkMute, letterSpacing: .8)),
        for (final n in names) MentionChip('@$n'),
      ],
    );
  }
}

class _ReplyQuote extends StatelessWidget {
  const _ReplyQuote({required this.preview});

  final ReplyPreview preview;

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    return Container(
      decoration: BoxDecoration(
        border: Border(left: BorderSide(color: s.hairlineStrong, width: 2)),
      ),
      padding: const EdgeInsets.only(left: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
              preview.seq == null
                  ? '回覆 ${preview.senderName ?? '（未知）'}'
                  : '回覆 ${preview.senderName ?? '（未知）'} · #${preview.seq}',
              style:
                  UepText.mono(size: 9, color: s.inkMute, letterSpacing: 1.0)),
          const SizedBox(height: 2),
          Text(
            preview.deleted ? '（原訊息已刪除）' : preview.excerpt,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: UepText.serif(size: 12, color: s.inkMute, height: 1.5),
          ),
        ],
      ),
    );
  }
}

/// 右鍵 / 長按叫出訊息管理選單（設計稿 MESSAGE #seq 選單）。
class _ContextMenuRegion extends StatelessWidget {
  const _ContextMenuRegion({
    required this.child,
    required this.message,
    required this.actions,
    required this.isSelf,
  });

  final Widget child;
  final Message message;
  final MessageActions? actions;

  /// 編輯只列給自己的訊息。**不是只靠 Hub 擋**——把一個必然失敗的選項擺
  /// 出來，跟不給的差別是使用者會先按下去才知道不行。
  final bool isSelf;

  Future<void> _showMenu(BuildContext context, Offset globalPos) async {
    final a = actions;
    if (a == null || message.deleted || message.isSystem) return;
    final s = context.uep;
    // **兩端都要指定 root，否則座標系對不上。**
    //
    // `globalPos` 是全視窗座標（`details.globalPosition`），而 `showMenu` 的
    // `position` 是**相對於它落腳的那個 Overlay**。`Overlay.of(context)` 預設
    // 取最近的一個，`showMenu` 預設用 `Navigator.of(context).overlay`——兩者
    // 在有巢狀 Navigator／Overlay 的畫面上不保證是同一個，於是選單會固定偏
    // 離游標一段距離（偏移量剛好是兩個 overlay 的原點差）。
    //
    // 明確都用 root：`rootOverlay: true` 與 `useRootNavigator: true` 成對出現，
    // 少一個就回到「大部分時候對」的狀態，而那種錯位只在特定畫面結構下現形。
    final overlay = Overlay.of(context, rootOverlay: true)
        .context
        .findRenderObject()! as RenderBox;
    final choice = await showMenu<String>(
      context: context,
      useRootNavigator: true,
      // 用 `fromRect` 而不是自己算四邊距離：把「點在哪」與「容器多大」分開
      // 交給 Flutter，邊緣翻轉（右緣/下緣溢出時自動往內收）也才會生效
      position: RelativeRect.fromRect(
        Rect.fromPoints(globalPos, globalPos),
        Offset.zero & overlay.size,
      ),
      color: s.bgCard,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: s.lineStrong),
      ),
      items: [
        PopupMenuItem(
          enabled: false,
          height: 30,
          child: Text('MESSAGE #${message.seq}',
              style:
                  UepText.mono(size: 8.5, color: s.inkMute, letterSpacing: 2)),
        ),
        // 封存房唯讀：只留複製，不列出一排停用的動作
        if (a.enabled) ...[
          PopupMenuItem(
            value: 'pin',
            height: 36,
            child: Text(message.pinned ? '❖　取消釘選' : '❖　釘選',
                style: UepText.sans(size: 12.5, color: s.ink)),
          ),
          PopupMenuItem(
            value: 'reply',
            height: 36,
            child: Text('↩　回覆', style: UepText.sans(size: 12.5, color: s.ink)),
          ),
          // 釘選與建立任務是兩件事，並存（同 Q1 的理由）：釘選是「這則訊息
          // 很重要」，任務是「這則訊息要有人去做」。而卡片會指回這裡——
          // 三百則訊息之後，那條路是唯一還找得到當初為什麼的東西
          PopupMenuItem(
            value: 'task',
            height: 36,
            child:
                Text('❖　建立任務', style: UepText.sans(size: 12.5, color: s.ink)),
          ),
          if (isSelf)
            PopupMenuItem(
              value: 'edit',
              height: 36,
              child:
                  Text('✎　編輯', style: UepText.sans(size: 12.5, color: s.ink)),
            ),
        ],
        PopupMenuItem(
          value: 'copy',
          height: 36,
          child:
              Text('⧉　複製內容', style: UepText.sans(size: 12.5, color: s.ink)),
        ),
        if (a.enabled) ...[
          const PopupMenuDivider(),
          PopupMenuItem(
            value: 'delete',
            height: 36,
            child: Text('✕　刪除（需確認）',
                style: UepText.sans(size: 12.5, color: UepColors.errorText)),
          ),
        ],
      ],
    );
    switch (choice) {
      case 'pin':
        a.onTogglePin(message);
      case 'reply':
        a.onReply(message);
      case 'task':
        a.onCreateTask(message);
      case 'copy':
        await Clipboard.setData(ClipboardData(text: message.content));
      case 'edit':
        a.onEdit(message);
      case 'delete':
        a.onDelete(message);
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onSecondaryTapUp: (d) => _showMenu(context, d.globalPosition),
      onLongPressStart: (d) => _showMenu(context, d.globalPosition),
      child: child,
    );
  }
}
