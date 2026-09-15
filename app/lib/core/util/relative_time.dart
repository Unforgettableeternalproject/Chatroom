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

/// 一段時長的中文顯示（閒置多久、還剩多久）。
///
/// 這與 [relativeTime] 是兩件事：那個答「什麼時候發生的」，這個答「持續了
/// 多久」。原本成員列直接印 `'閒置 $minutes 分'`，於是掛了兩天的 agent 會
/// 顯示「閒置 3120 分」——**那個數字要讀的人自己去除以 60**，而畫面存在的
/// 意義就是免去這件事。
///
/// 進位到日為止。為 0 的尾段不顯示（`120 分` → `2 時`，不是 `2 時 0 分`），
/// 但中間段保留（`1500 分` → `1 日 1 時`），否則 `1 日 5 分` 會讀成
/// 「一天又五分鐘」與「一天一小時五分」分不出來。
String humanDuration(Duration d) {
  if (d.isNegative) return '0 分';
  final days = d.inDays;
  final hours = d.inHours % 24;
  final minutes = d.inMinutes % 60;

  if (days > 0) {
    final parts = ['$days 日'];
    if (hours > 0) parts.add('$hours 時');
    if (minutes > 0) parts.add('$minutes 分');
    return parts.join(' ');
  }
  if (hours > 0) {
    return minutes > 0 ? '$hours 時 $minutes 分' : '$hours 時';
  }
  return '$minutes 分';
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
