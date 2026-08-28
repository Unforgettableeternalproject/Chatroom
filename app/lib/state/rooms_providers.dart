import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/rooms_api.dart';
import '../models/room.dart';
import 'app_providers.dart';

/// 房間列表（status = active | archived）。
/// 動作（建立/封存/解封）完成後由呼叫端 invalidate。
final roomListProvider =
    FutureProvider.family<List<Room>, String>((ref, status) async {
  final api = ref.watch(roomsApiProvider);
  final result = await api.list(status: status);
  return result.rooms;
});

/// 房間 + 成員。斷線補訊後與進房時各自 invalidate 一次。
final roomDetailProvider =
    FutureProvider.autoDispose.family<RoomDetail, String>((ref, roomId) async {
  final api = ref.watch(roomsApiProvider);
  final detail = await api.detail(roomId);
  // 累積最近見過的 agent session_key（指派快選用；detail 不含 session_key
  // 時此步為 no-op，快選仍有手動輸入的路）
  final keys = detail.participants
      .where((p) => !p.isHuman && p.sessionKey != null)
      .map((p) => p.sessionKey!);
  if (keys.isNotEmpty) {
    await ref.read(settingsRepoProvider).rememberSessionKeys(keys);
  }
  return detail;
});
