import 'package:flutter/foundation.dart';

import 'attachment.dart';

@immutable
class ReplyPreview {
  const ReplyPreview({
    required this.senderName,
    required this.excerpt,
    required this.deleted,
    this.seq,
  });

  final String? senderName;
  final String excerpt;
  final bool deleted;

  /// 被回覆訊息的房內序號。內容可以被軟刪除，seq 不會——「回的是哪一則」
  /// 只有它答得出來。舊版 Hub 不回這個欄位。
  final int? seq;

  factory ReplyPreview.fromJson(Map<String, dynamic> json) => ReplyPreview(
        senderName: json['sender_name'] as String?,
        excerpt: (json['excerpt'] as String?) ?? '',
        deleted: (json['deleted'] as bool?) ?? false,
        seq: json['seq'] as int?,
      );
}

@immutable
class Message {
  const Message({
    required this.id,
    required this.seq,
    required this.updateSeq,
    required this.kind,
    required this.content,
    required this.createdAt,
    this.senderId,
    this.senderName,
    this.mentions = const [],
    this.mentionGroups = const [],
    this.editedAt,
    this.replyTo,
    this.replyToSeq,
    this.replyPreview,
    this.pinned = false,
    this.deleted = false,
    this.systemEvent,
    this.attachments = const [],
  });

  final String id;

  /// 房內遞增序號——排序與去重的唯一依據。
  /// ⚠️ seq 與 update_seq 共用 room.next_seq 計數器，所以 seq 天生有洞；
  /// cursor 一律用 max(seq, update_seq) 的最大值，絕不能用「連續前綴」。
  final int seq;
  final int updateSeq;
  final String kind; // chat | system
  final String content;
  final String createdAt;
  final String? senderId;
  final String? senderName;
  final List<String> mentions;

  /// 發話者原本打的群組字面（`["all"]`）。**展開在 Hub 那端做**，所以
  /// [mentions] 已經是實名清單——這個欄位只是為了讓 UI 還原成一顆 `@all`
  /// chip，而不是掛一整排全房名單。
  ///
  /// 舊版 Hub 不回這個欄位，缺了就是空清單：那時 [mentions] 本來也不會有
  /// 展開的結果，兩邊自然一致。
  final List<String> mentionGroups;

  /// 這則被編輯過的時間；沒編輯過就是 null。
  ///
  /// **UI 一定要畫出來**：編輯與刪除的差別正在於「改了看不出來」——那是
  /// 權限界線把建立者擋在外面的理由（刪除他做得到，編輯不行）。標記沒畫，
  /// 那條界線就在最後一哩失守。
  final String? editedAt;
  final String? replyTo;

  /// 被回覆訊息的房內序號。Hub 端「回覆＝mention 被回覆的人」，這個序號
  /// 是那則訊息帶著走的指向。舊訊息與舊版 Hub 為 null。
  final int? replyToSeq;
  final ReplyPreview? replyPreview;
  final bool pinned;
  final bool deleted;

  /// system 訊息的機器可讀事件名（join / leave / kick / idle_removed /
  /// archive…）。chat 訊息一律為 null。
  ///
  /// 存在的理由是**不要拿中文內容去比對**——「X 加入了聊天室」改一個字，
  /// 依賴字串比對的 client 就會無聲失效，而且沒有任何地方會報錯。
  final String? systemEvent;

  bool get isSystem => kind == 'system';

  /// 夾帶的檔案（內容在 Hub 的磁碟上，這裡只有 metadata）。
  final List<Attachment> attachments;

  /// 有人加入房間。dispatcher 據此喚醒房內的本機 agent。
  bool get isMemberJoined => systemEvent == 'join';

  /// 「收據」類的系統訊息：提問有了答案、訊息被釘選。
  ///
  /// 與 join/leave 那種一行帶過的事件不同，收據帶著**內容**（答案全文、
  /// 被釘的是誰的哪一則），塞進髮絲線中間的一行小字會被截斷成沒有用的東西，
  /// 所以要另外渲染。
  static const receiptEvents = {
    'question_answered',
    'question_skipped',
    'pin',
  };

  bool get isReceipt => receiptEvents.contains(systemEvent);

  /// 此則訊息對 cursor 的貢獻值。
  int get cursor => seq > updateSeq ? seq : updateSeq;

  factory Message.fromJson(Map<String, dynamic> json) => Message(
        id: json['id'] as String,
        seq: json['seq'] as int,
        updateSeq: (json['update_seq'] as int?) ?? 0,
        kind: (json['kind'] as String?) ?? 'chat',
        content: (json['content'] as String?) ?? '',
        createdAt: (json['created_at'] as String?) ?? '',
        senderId: json['sender_id'] as String?,
        senderName: json['sender_name'] as String?,
        mentions: ((json['mentions'] as List?) ?? const [])
            .map((e) => e.toString())
            .toList(),
        mentionGroups: ((json['mention_groups'] as List?) ?? const [])
            .map((e) => e.toString())
            .toList(),
        editedAt: json['edited_at'] as String?,
        replyTo: json['reply_to'] as String?,
        replyToSeq: json['reply_to_seq'] as int?,
        replyPreview: json['reply_preview'] == null
            ? null
            : ReplyPreview.fromJson(
                json['reply_preview'] as Map<String, dynamic>),
        pinned: (json['pinned'] as bool?) ?? false,
        deleted: (json['deleted'] as bool?) ?? false,
        systemEvent: json['system_event'] as String?,
        attachments: ((json['attachments'] as List?) ?? const [])
            .map((e) => Attachment.fromJson(e as Map<String, dynamic>))
            .toList(),
      );

  @override
  bool operator ==(Object other) =>
      other is Message && other.id == id && other.cursor == cursor;

  @override
  int get hashCode => Object.hash(id, cursor);
}
