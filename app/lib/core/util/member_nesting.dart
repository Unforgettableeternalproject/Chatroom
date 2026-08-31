import '../../models/participant.dart';

/// 把 subagent 排到它父層的正下方，其餘維持原本的順序。
///
/// 不做成 `sort`：subagent 之間、以及一般成員之間的既有順序（joined_at）
/// 都要保留，只是把子代理「插」回父層後面。父層不在這份清單裡的（理論上
/// 不會發生——級聯移除保證它們同進同出）就照原位留著，**不要丟掉**：
/// 看不見的成員比排錯位置的成員危險得多。
List<Participant> nestSubagents(List<Participant> members) {
  final byParent = <String, List<Participant>>{};
  for (final p in members) {
    if (p.ephemeral && p.parentId != null) {
      byParent.putIfAbsent(p.parentId!, () => []).add(p);
    }
  }
  if (byParent.isEmpty) return members;

  final placed = <String>{};
  final out = <Participant>[];
  for (final p in members) {
    if (p.ephemeral && p.parentId != null && byParent.containsKey(p.parentId)) {
      continue; // 由父層那一輪帶出來
    }
    out.add(p);
    for (final child in byParent[p.id] ?? const <Participant>[]) {
      out.add(child);
      placed.add(child.id);
    }
  }
  // 父層不在清單裡的孤兒：補在最後，寧可位置不漂亮也不要消失
  for (final children in byParent.values) {
    for (final c in children) {
      if (!placed.contains(c.id)) out.add(c);
    }
  }
  return out;
}
