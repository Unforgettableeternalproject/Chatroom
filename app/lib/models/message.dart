import 'package:flutter/foundation.dart';

import 'attachment.dart';

@immutable
class ReplyPreview {
  const ReplyPreview({
    required this.senderName,
    required this.excerpt,
    required this.deleted,
  });

  final String? senderName;
  final String excerpt;
  final bool deleted;

  factory ReplyPreview.fromJson(Map<String, dynamic> json) => ReplyPreview(
        senderName: json['sender_name'] as String?,
        excerpt: (json['excerpt'] as String?) ?? '',
        deleted: (json['deleted'] as bool?) ?? false,
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
    this.replyTo,
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
  final String? replyTo;
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
        replyTo: json['reply_to'] as String?,
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
