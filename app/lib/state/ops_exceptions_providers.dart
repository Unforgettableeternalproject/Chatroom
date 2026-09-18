import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/ops_exceptions_api.dart';
import '../notifications/local_notifier.dart';
import '../notifications/ops_exception_notifier.dart';
import '../models/ops_exception.dart';
import 'app_providers.dart';

/// 監控器（跨房派工例外）的狀態層。整條功能線收在自己的檔案裡，
/// 既有檔案不必為它改（同 `runs_providers` 的慣例）。
final opsExceptionsApiProvider =
    Provider((ref) => OpsExceptionsApi(ref.watch(dioProvider)));

/// 最近的例外清單。
///
/// ⚠️ `autoDispose`：與執行儀表板同一個理由——沒有人在看的畫面不該每
/// 10 秒叫一次 Hub。定時 invalidate 在畫面層，不在這裡。
///
/// **每次都從頭撈最近 50 筆，不帶游標**：游標是「通知投過沒」的水位
/// （見 `OpsExceptionSeen`），不是清單的起點。拿它當起點的話，面板在
/// 第二次刷新時會變成空的。
final opsExceptionsProvider =
    FutureProvider.autoDispose<List<OpsException>>((ref) async {
  final api = ref.watch(opsExceptionsApiProvider);
  final key = ref.watch(appConfigProvider).deviceKey;
  if (key.isEmpty) return const [];
  final page = await api.list(sessionKey: key, limit: 50);
  return page.exceptions;
});

/// 「看到哪裡了」的水位：本機記最後一筆看過的事件時間。
///
/// 記時間不記 id：id 只認得出「那一筆」，而清單是跨房合併出來的，
/// 判斷「這筆比我看過的新」要能比大小。時間字串是 Hub 給的 ISO 值，
/// 字典序與時序一致。
class OpsExceptionSeen extends Notifier<String> {
  @override
  String build() => ref.read(settingsRepoProvider).opsExceptionSeenAt;

  /// 看過了：帶這一批裡最新的那筆時間。
  ///
  /// **只會往前不會往後**：面板在輪詢之間可能拿到比水位舊的一批
  /// （例如篩選後的清單），往回寫等於讓已經看過的東西重新變成未讀。
  Future<void> markSeen(String createdAt) async {
    if (createdAt.isEmpty || createdAt.compareTo(state) <= 0) return;
    state = createdAt;
    await ref.read(settingsRepoProvider).setOpsExceptionSeenAt(createdAt);
  }
}

final opsExceptionSeenProvider =
    NotifierProvider<OpsExceptionSeen, String>(OpsExceptionSeen.new);

/// 未讀筆數＝比水位新的那幾筆。
int unreadExceptionCount(List<OpsException> list, String seenAt) =>
    list.where((e) => e.createdAt.compareTo(seenAt) > 0).length;

/// 例外 → 系統通知的管線。App 起來時 start 一次（見 `app.dart`）。
///
/// **不接 [opsExceptionsProvider]**：那一格是 autoDispose 的畫面資料，
/// 掛在它上面等於讓一個沒有人在看的畫面一直活著。通知這條自己撈。
final opsExceptionNotifierProvider = Provider<OpsExceptionNotifier>((ref) {
  final notifier = OpsExceptionNotifier(
    fetch: () async {
      final key = ref.read(appConfigProvider).deviceKey;
      if (key.isEmpty) return const [];
      final page =
          await ref.read(opsExceptionsApiProvider).list(sessionKey: key);
      return page.exceptions;
    },
    show: LocalNotifier.instance.show,
  );
  ref.onDispose(notifier.dispose);
  return notifier;
});
