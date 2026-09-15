import '../models/message.dart';

/// 把一段對話排版成人看的 log。
///
/// 分工：**原始 jsonl 由 Hub 出，排版留在這裡**——排版不影響任何 agent 的
/// 行為，屬於呈現層（對照 Hub 只把「影響行為的定稿」收在自己手上，例如房間
/// 的說話方式）。這裡是純函式，不碰 IO，存檔那一段另外處理。
///
/// 時間一律原樣輸出 Hub 給的 UTC 字串並標上 `Z`。**不轉本地時間**：匯出檔
/// 會被寄出、貼進 issue、跨時區傳閱，而一個沒有時區標記的「09:15」在收件人
/// 手上是無法還原的——那種歧義比多兩個字元貴得多。
String formatConversationLog({
  required String roomName,
  required Iterable<Message> messages,
}) {
  final buffer = StringBuffer()
    ..writeln('# $roomName')
    ..writeln();
  for (final m in messages) {
    buffer.writeln(_formatMessage(m));
  }
  return buffer.toString();
}

String _formatMessage(Message m) {
  final time = _formatTime(m.createdAt);
  // 撤回的訊息 content 已被 Hub 清空，照印會變成一行空白的發言——那看起來
  // 像資料壞掉，而不像「這則被撤回了」
  if (m.deleted) {
    return '[$time] ${_who(m)}：（已撤回）';
  }
  if (m.isSystem) {
    return '[$time] · ${m.content}';
  }

  final head = StringBuffer('[$time] ${_who(m)}');
  if (m.pinned) head.write(' 📌');
  // 回覆指向 seq 而不是內容：內容可以被撤回，seq 不會——「回的是哪一則」
  // 只有它答得出來
  if (m.replyToSeq != null) head.write(' ↩ #${m.replyToSeq}');
  head.write('：');

  final body = StringBuffer(head.toString())..write(m.content);
  for (final a in m.attachments) {
    body.write('\n    📎 ${a.filename}（${a.readableSize}）');
  }
  return body.toString();
}

/// 發送者。system 訊息與極舊的資料可能沒有名字，那時不要印出空字串——
/// 「誰說的」缺席要看得出來是缺席。
String _who(Message m) => (m.senderName?.isNotEmpty ?? false)
    ? m.senderName!
    : (m.senderId == null ? '（系統）' : '（不明）');

/// `2026-08-31T09:15:22.480645+00:00` → `2026-08-31 09:15:22Z`。
///
/// 解析不了就原樣輸出：匯出的價值在於完整，為了排版把看不懂的時間吞掉
/// 是本末倒置。
String _formatTime(String iso) {
  final parsed = DateTime.tryParse(iso);
  if (parsed == null) return iso;
  final u = parsed.toUtc();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${u.year}-${two(u.month)}-${two(u.day)} '
      '${two(u.hour)}:${two(u.minute)}:${two(u.second)}Z';
}
