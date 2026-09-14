import 'package:flutter/foundation.dart';

/// Hub 掃描到的 agent session（GET /api/sessions）。
/// 指派畫面據此列出可指派對象，不必使用者手抄 session_key。
@immutable
class AgentSession {
  const AgentSession({
    required this.sessionKey,
    required this.kind,
    required this.label,
    required this.status,
    required this.lastSeenAt,
    required this.rooms,
    this.lastDisplayName,
    this.lastIp,
    this.host = '',
    this.labelSelfReported = true,
  });

  final String sessionKey;
  final String kind; // claude | codex | other
  final String label; // bridge 自報的代稱，可能為空
  final String status; // active | idle
  final String lastSeenAt;

  /// 目前所在的房間（含房內顯示名稱）。
  final List<SessionRoom> rooms;

  /// 不在任何房內時，最近一次用過的房內名稱（辨識用）。
  final String? lastDisplayName;

  /// 最近一次連線的來源位址。**僅供辨識**——共用一把 token 時 Hub 眼中
  /// 所有人長得一樣，這是邀請清單上唯一分得開「這是誰」的線索。
  /// 它來自客戶端可填寫的標頭，不可用於任何授權判斷。
  final String? lastIp;

  /// bridge／App 自報的主機名。空字串＝舊版 bridge 沒報，那是「未知裝置」。
  ///
  /// ⚠️ 空值**不能**當成本機：每一台取不到主機名的機器都會混進本機清單，
  /// 而指派是私人房的入場券。
  final String host;

  /// [label] 是 agent 自己報的，還是只是被探索到的佔位。
  ///
  /// false ＝ 這個 session 從來沒接過聊天室（沒有 chatroom MCP，或還沒用過）。
  /// VS Code 擴充套件、Codex 桌面 App、subagent thread 都長這樣——它們與
  /// CLI 共用同一個 writer lock 目錄，所以 App 看得到，但它們永遠不會自報。
  ///
  /// ⚠️ 不能拿它當「不是候選人」：**第一次**指派一個全新的 Codex 時，
  /// 它本來就還沒自報過。這是排序與摺疊的依據，不是過濾的依據。
  final bool labelSelfReported;

  /// 這個 session 接入過聊天室沒有。
  ///
  /// **人在房內是最強的證據**，比自報過名字還強——所以它排在前面。
  ///
  /// ⚠️ 只看 [labelSelfReported] 會漏掉正在房裡的 agent：那面旗標要等
  /// 對方主動碰一次 Hub 才會翻，而 Codex **沒有週期性心跳**，它只在真的
  /// 呼叫 chatroom 工具時才報到。閒著的時候它就一直是 false，於是房裡
  /// 明明坐著的那個 agent 被收進「尚未接入聊天室」（2026-09-14 實測，
  /// 艾斯維爾在畫面上抓到）。
  bool get linkedToChatroom => rooms.isNotEmpty || labelSelfReported;

  /// 這個 session 是不是跑在 [me] 這台機器上。
  ///
  /// 兩邊都要有值才算數，比對忽略大小寫——Windows 慣用大寫、Dart 拿到的
  /// 可能是小寫，同一台機器不該因此被判成兩台。
  bool isOnHost(String me) =>
      host.isNotEmpty && me.isNotEmpty && host.toLowerCase() == me.toLowerCase();

  bool get isHuman => kind == 'human';
  bool get isActive => status == 'active';

  /// 給清單顯示的主名稱：代稱 > 房內名稱 > 歷史名稱 > key 尾碼。
  String get displayTitle {
    if (label.isNotEmpty) return label;
    if (rooms.isNotEmpty) return rooms.first.displayName;
    if (lastDisplayName != null && lastDisplayName!.isNotEmpty) {
      return lastDisplayName!;
    }
    final tail = sessionKey.length > 8
        ? sessionKey.substring(sessionKey.length - 8)
        : sessionKey;
    return '$kind-$tail';
  }

  factory AgentSession.fromJson(Map<String, dynamic> json) => AgentSession(
        sessionKey: (json['session_key'] as String?) ?? '',
        kind: (json['kind'] as String?) ?? 'other',
        label: (json['label'] as String?) ?? '',
        status: (json['status'] as String?) ?? 'idle',
        lastSeenAt: (json['last_seen_at'] as String?) ?? '',
        rooms: ((json['rooms'] as List?) ?? const [])
            .map((e) => SessionRoom.fromJson(e as Map<String, dynamic>))
            .toList(),
        lastDisplayName: json['last_display_name'] as String?,
        lastIp: json['last_ip'] as String?,
        host: (json['host'] as String?) ?? '',
        // 舊 Hub 沒有這一欄——**預設 true**。當成「探索到的」會讓所有既有
        // session 一夕之間全被收進摺疊區，而那看起來像 agent 全部消失了
        labelSelfReported: (json['label_self_reported'] as bool?) ?? true,
      );
}

@immutable
class SessionRoom {
  const SessionRoom({
    required this.roomId,
    required this.roomName,
    required this.displayName,
  });

  final String roomId;
  final String roomName;
  final String displayName;

  factory SessionRoom.fromJson(Map<String, dynamic> json) => SessionRoom(
        roomId: (json['room_id'] as String?) ?? '',
        roomName: (json['room_name'] as String?) ?? '',
        displayName: (json['display_name'] as String?) ?? '',
      );
}
