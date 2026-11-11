import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/scratchpad_api.dart';
import '../models/scratchpad.dart';
import 'app_providers.dart';

final scratchpadApiProvider = Provider<ScratchpadApi>(
  (ref) => ScratchpadApi(ref.watch(dioProvider)),
);

final watchApiProvider = Provider<WatchApi>(
  (ref) => WatchApi(ref.watch(dioProvider)),
);

/// 一塊板上的想法板清單。
final scratchpadListProvider =
    FutureProvider.family<List<ScratchpadSummary>, String>((ref, boardId) {
  final key = ref.watch(appConfigProvider).deviceKey;
  return ref.watch(scratchpadApiProvider).list(boardId, sessionKey: key);
});

/// 一份想法板的全文。
///
/// ⚠️ key 用 `boardId/padId` 併起來：只用 padId 的話，同一份板在兩塊板底下
/// （理論上不會，但 provider 不該假設）會共用同一格快取。
final scratchpadProvider =
    FutureProvider.family<Scratchpad, String>((ref, key) {
  final parts = key.split('/');
  final sessionKey = ref.watch(appConfigProvider).deviceKey;
  return ref
      .watch(scratchpadApiProvider)
      .fetch(parts[0], parts[1], sessionKey: sessionKey);
});

String scratchpadKey(String boardId, String padId) => '$boardId/$padId';
