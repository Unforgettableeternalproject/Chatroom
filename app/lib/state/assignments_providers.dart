import 'package:flutter_riverpod/flutter_riverpod.dart';

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
