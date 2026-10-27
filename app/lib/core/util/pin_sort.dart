/// 把被關注的項目排到最前面。
///
/// 穩定排序：關注項之間、非關注項之間都維持 [items] 原本的相對順序，
/// 所以呼叫端先套過濾與既有排序，再交給這裡即可。不改動傳入的清單。
List<T> pinnedFirst<T>(Iterable<T> items, bool Function(T item) isPinned) {
  final pinned = <T>[];
  final rest = <T>[];
  for (final item in items) {
    (isPinned(item) ? pinned : rest).add(item);
  }
  return [...pinned, ...rest];
}
