import 'package:flutter/foundation.dart';

/// App 的版本識別。
///
/// 存在的理由是一次真實事故：測試端手上的 App 是 16 小時前的產物，中間隔著
/// 17 個 commit，而畫面上沒有任何資訊能分辨——連「我記得我 rebuild 過」都
/// 無從查證。（真正的成因是每次 rebuild 都因 exe 被佔用而失敗，只留下一行
/// 淹在輸出裡的 LNK1104，舊產物完好地待在原地。）
///
/// 所以版本字串一定要帶 **commit hash**。語意版本號（`1.0.0`）只說得出
/// 「這是哪一版設計」，說不出「這是哪一份程式碼」，而後者才是回報問題時
/// 真正要問的那一個。
///
/// ⚠️ commit 取不到時**不偽造成好看的預設值**。「不知道自己是哪一版」與
/// 「是 1.0.0 版」是完全不同的兩件事，把前者顯示成後者正是這次事故的成因。
/// 與 Hub 的 `chatroom_server/version.py` 是同一套語意，兩邊才比得起來。
@immutable
class BuildInfo {
  const BuildInfo({
    required this.version,
    required this.commit,
    required this.builtAt,
  });

  /// 人看的「這是哪一版設計」。
  final String version;

  /// 這是哪一份程式碼。build 時由 `--dart-define=CHATROOM_COMMIT=...` 帶入；
  /// 沒帶就是空字串——空字串是誠實的答案，不要拿版本號去填。
  ///
  /// 帶 `-dirty` 後綴表示 build 當下工作樹有未提交的變更，那份產物對不回
  /// 任何一個 commit。
  final String commit;
  final String builtAt;

  /// 這份 App 講不講得出自己是哪一份程式碼。
  bool get isKnown => commit.isNotEmpty;

  /// 產物對不回任何一個 commit。
  bool get isDirty => commit.endsWith('-dirty');

  /// 給人看的一行。**取不到時明說 unknown**，不退回版本號。
  String get label =>
      isKnown ? '$version+$commit' : '$version（commit 未知）';

  static const _version = String.fromEnvironment(
    'CHATROOM_VERSION',
    defaultValue: '1.0.0',
  );
  static const _commit = String.fromEnvironment('CHATROOM_COMMIT');
  static const _builtAt = String.fromEnvironment('CHATROOM_BUILT_AT');

  /// 這份 build 的識別。`--dart-define` 的值在編譯期就固定，執行期改不了。
  static const current =
      BuildInfo(version: _version, commit: _commit, builtAt: _builtAt);

  /// 與 Hub `/api/health` 回的 `build` 比對。
  ///
  /// 任一邊講不出自己是哪一份時回 [VersionMatch.unknown]——那不是「相符」。
  /// 把「無法比對」顯示成「相符」等於把這整套機制關掉，而且關得無聲無息。
  static VersionMatch compare(BuildInfo app, Map<String, dynamic>? hubBuild) {
    final hubCommit = (hubBuild?['commit'] as String?) ?? '';
    if (!app.isKnown || hubCommit.isEmpty) return VersionMatch.unknown;
    // 兩邊的短 hash 長度可能不同（App 由 build 指令帶入、Hub 用 rev-parse
    // --short=12）。比前綴而不是要求等長，否則同一顆 commit 會被判成不符。
    final a = app.commit, b = hubCommit;
    final same = a.startsWith(b) || b.startsWith(a);
    return same ? VersionMatch.same : VersionMatch.different;
  }
}

enum VersionMatch {
  /// 同一份程式碼。
  same,

  /// 明確對不上——其中一邊沒有更新，功能會對不起來。
  different,

  /// 至少一邊講不出自己是哪一份。**不等於相符。**
  unknown,
}
