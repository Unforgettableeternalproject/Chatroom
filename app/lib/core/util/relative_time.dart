/// ISO 時間字串 → 相對時間中文顯示。
/// server 存 UTC ISO 格式；顯示一律轉本地時區。
String relativeTime(String? iso, {DateTime? now}) {
  final t = parseIso(iso);
  if (t == null) return '—';
  final ref = now ?? DateTime.now();
  final diff = ref.difference(t);
  if (diff.inSeconds < 60) return '剛剛';
  if (diff.inMinutes < 60) return '${diff.inMinutes} 分前';
  if (diff.inHours < 24 && ref.day == t.day) return '${diff.inHours} 小時前';
  final yesterday = ref.subtract(const Duration(days: 1));
  if (t.year == yesterday.year &&
      t.month == yesterday.month &&
      t.day == yesterday.day) {
    return '昨天';
  }
  if (diff.inDays < 365) {
    return '${_two(t.month)}-${_two(t.day)}';
  }
  return '${t.year}-${_two(t.month)}-${_two(t.day)}';
}

/// 訊息時間戳（HH:mm；跨日加上日期）。
String clockTime(String? iso, {DateTime? now}) {
  final t = parseIso(iso);
  if (t == null) return '';
  final ref = now ?? DateTime.now();
  final hm = '${_two(t.hour)}:${_two(t.minute)}';
  if (t.year == ref.year && t.month == ref.month && t.day == ref.day) {
    return hm;
  }
  return '${_two(t.month)}-${_two(t.day)} $hm';
}

DateTime? parseIso(String? iso) {
  if (iso == null || iso.isEmpty) return null;
  return DateTime.tryParse(iso)?.toLocal();
}

String _two(int n) => n.toString().padLeft(2, '0');
