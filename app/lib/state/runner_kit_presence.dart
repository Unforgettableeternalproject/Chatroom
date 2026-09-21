import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'runner_kit_providers.dart';

/// 這台機器有沒有裝 runner-kit——建房對話框用它決定「工作房」能不能選。
///
/// 判準與執行器分頁**同一份**（`runnerKitProvider`）：兩邊各判一次的話，
/// 註冊檔缺 `config` 時會出現「建房說裝了、分頁卻不出現」的矛盾。
/// 載入中一律當沒裝，不讓人先按下去再被擋。
final runnerKitPresentProvider = FutureProvider<bool>((ref) async {
  return await ref.watch(runnerKitProvider.future) != null;
});
