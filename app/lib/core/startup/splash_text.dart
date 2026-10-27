import 'dart:math';

/// 從使用者設定的字樣挑出這次啟動要顯示的一則。
///
/// [raw] 是設定頁的原始內容：一行一則。只有一則＝固定字樣；多則＝每次
/// 啟動隨機挑一則；全空或只有空白＝退回 [fallback]。
String pickSplashText(String raw, {required String fallback, Random? random}) {
  final candidates = splashCandidates(raw);
  if (candidates.isEmpty) return fallback;
  if (candidates.length == 1) return candidates.first;
  return candidates[(random ?? Random()).nextInt(candidates.length)];
}

/// 拆成非空候選（去頭尾空白、略過空行）。
List<String> splashCandidates(String raw) => raw
    .split(RegExp(r'\r?\n'))
    .map((l) => l.trim())
    .where((l) => l.isNotEmpty)
    .toList();
