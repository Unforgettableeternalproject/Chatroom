import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/rooms_api.dart';
import '../models/assignment.dart';
import 'app_providers.dart';

/// 房間列表（status = active | archived）。
/// 動作（建立/封存/解封）完成後由呼叫端 invalidate。
///
/// 帶自己的 session key 有兩個作用：Hub 會一併回傳指派給我的待處理邀請，
/// 而且會把我登記進 session 名錄——別人要邀我進房時，得先在清單上看得到我。
final roomListProvider =
    FutureProvider.family<RoomListResult, String>((ref, status) async {
  final api = ref.watch(roomsApiProvider);
  final config = ref.watch(appConfigProvider);
  // 主持人模式切換時要重撈——列表的內容會從「有份的房」變成「全部的房」。
  // dio 的 interceptor 是現讀的，但 provider 不 watch 就不會知道該重跑
  ref.watch(hostViewProvider);
  return api.list(
    status: status,
    sessionKey: config.deviceKey,
    label: config.preferredName,
  );
});

/// 指派給我的待處理邀請。與房間列表同一次請求取得，不另外輪詢。
final myPendingInvitesProvider = Provider<List<Assignment>>((ref) =>
    ref.watch(roomListProvider('active')).value?.pendingAssignments ??
    const []);

/// 房間 + 成員。斷線補訊後與進房時各自 invalidate 一次。
final roomDetailProvider =
    FutureProvider.autoDispose.family<RoomDetail, String>((ref, roomId) async {
  final api = ref.watch(roomsApiProvider);
  // 帶自己的 session key：Hub 回 you_are_admin（建立者可移出成員）
  final deviceKey = ref.watch(appConfigProvider.select((c) => c.deviceKey));
  // 房間是讀取邊界，房間詳情要成員身分才讀得到。用**快取的** participant id
  // 而不是 await identityProvider：那會讓詳情等 join 完成，而 join 失敗時
  // 連「這個房間長什麼樣」都看不到，錯誤畫面反而更難懂。首次進房時是 null，
  // join 完成後由畫面層 invalidate 這個 provider 補上。
  final cached = ref.watch(settingsRepoProvider).participantId(roomId);
  final detail =
      await api.detail(roomId, sessionKey: deviceKey, participantId: cached);
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
