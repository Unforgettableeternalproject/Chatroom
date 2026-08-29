import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/tokens_api.dart';
import '../models/agent_session.dart';
import '../models/assignment.dart';
import 'app_providers.dart';

/// 房間視角的指派列表。畫面開著時由畫面層週期 invalidate
/// （agent 接受指派沒有 WS 事件，只能輪詢）。
final roomAssignmentsProvider = FutureProvider.autoDispose
    .family<List<Assignment>, String>((ref, roomId) async {
  final api = ref.watch(assignmentsApiProvider);
  return api.listForRoom(roomId);
});

/// Hub 掃描到的 agent session（active/idle）。指派畫面的對象清單，
/// 與指派列表共用畫面層的週期 invalidate。
final agentSessionsProvider =
    FutureProvider.autoDispose<List<AgentSession>>((ref) async {
  final api = ref.watch(assignmentsApiProvider);
  return api.scanSessions();
});

/// 已連上 Hub 的人類 session。邀請人類進房的候選清單。
///
/// 只列已連線的人——沒連上 Hub 的人邀了也收不到，那種情況要先給他一份
/// 邀請碼（設定頁的「邀請成員」），那是另一件事。
final humanSessionsProvider =
    FutureProvider.autoDispose<List<AgentSession>>((ref) async {
  final api = ref.watch(assignmentsApiProvider);
  final all = await api.scanSessions(includeHuman: true);
  return all.where((s) => s.isHuman).toList();
});

/// 已發出的邀請 token。只有主 token 拿得到，其餘會是 403——
/// 那不是錯誤，是「這台不是你主持的」。
final accessTokensProvider =
    FutureProvider.autoDispose<List<AccessToken>>((ref) async {
  final api = ref.watch(tokensApiProvider);
  return api.list();
});
