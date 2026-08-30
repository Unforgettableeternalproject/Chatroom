import 'dart:io';

/// 這台機器的名字，自報給 Hub 用。
///
/// 指派 UI 靠它把「我這台機器上的 agent」與「別人機器上的」分開——指派是
/// 私人房的入場券，把別人的 agent 指派進來，等於把房裡的內容送出去。
/// bridge 那邊的對應物是 `identity.host_name()`，兩邊要取到同一個值才比得起來
/// （都用作業系統的 hostname；bridge 可用 CHATROOM_HOST_NAME 覆寫）。
///
/// ⚠️ 這是**自報**的值，僅供辨識與分組，不是授權依據。信任邊界仍是 token。
///
/// 取不到就回空字串——空值在 UI 上是「未知裝置」，不能當成本機。
final String localHostName = _readHostName();

String _readHostName() {
  try {
    return Platform.localHostname.trim();
  } on Object {
    // 某些沙箱環境讀不到主機名，這不該讓房間列表整個失敗
    return '';
  }
}
