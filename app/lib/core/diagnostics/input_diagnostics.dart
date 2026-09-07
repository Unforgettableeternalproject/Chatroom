import 'dart:io';

import 'package:flutter/foundation.dart';

/// 輸入卡死的診斷儀器（卡 `7d3db264` 第一階段）。
///
/// ## 為什麼是儀器而不是又一個假設
///
/// 2026-09-07 我們對「注音打到一半不能動」提了七條假設，**七條全倒**：
/// collection-if 重建、`_hasText` 的 setState、long-poll、WS 心跳、
/// 工作列角標的 Win32 呼叫、`upsertAll` 的無謂 notify、跨行導致 caret
/// 重定位。每一條都聽起來合理，而艾斯維爾每提供一次新觀察就倒一條。
///
/// **猜的成本已經超過測的成本。** 這個檔案的用途是：下一次發作時，
/// 不必有人記得當下發生了什麼——log 自己會說。
///
/// ## 四種事件、同一條 log、同一個時鐘
///
/// 焦點、IME 組字、視窗前後景、Win32 角標呼叫。**分開記等於沒記**：
/// 這個症狀只能靠時序判斷，而四份各自為政的時間戳事後拼不回去。
///
/// 時間戳有兩個，缺一不可：
/// - `t` ＝ App 啟動以來的毫秒（**單調**）。時序分析看這個——牆鐘會被
///   NTP 校正、會被使用者改，那會讓事件在事後排出錯誤的順序
/// - `at` ＝ 牆鐘。人要對得上「我大概是那個時候撞到的」，只有它做得到
///
/// ## 不記內容，只記形狀
///
/// 打了什麼字**不寫進檔案**——那是使用者正在說的話，而且對這個症狀沒有
/// 用。要的是長度、行數、composing 的範圍。少了這條約束，這份 log 就會
/// 變成一個沒有人敢交出來的東西。
class InputDiagnostics {
  InputDiagnostics._();

  static final instance = InputDiagnostics._();

  /// 開關。**預設開**——這個症狀只在艾斯維爾的實機出現，關著等於沒做。
  /// 關掉時每個呼叫點都是一次 `return`，成本可以忽略。
  bool enabled = true;

  /// 單調時鐘。從 App 啟動算起，不受系統時間調整影響。
  final _since = Stopwatch()..start();

  IOSink? _sink;
  File? _file;
  bool _opening = false;

  /// 單檔上限。滿了就輪替一次，只留一份舊的——這是診斷不是稽核，
  /// 留兩份以上只會佔空間，而我們要的永遠是「最近一次發作」附近那段。
  static const _maxBytes = 1024 * 1024;

  /// log 落點。**不加 path_provider**：多一個依賴就要重打包一次，
  /// 而 Windows 桌面版拿得到 `%LOCALAPPDATA%`。
  File? _resolveFile() {
    if (!Platform.isWindows) return null;
    final base = Platform.environment['LOCALAPPDATA'] ??
        Platform.environment['USERPROFILE'];
    if (base == null || base.isEmpty) return null;
    final dir = Directory('$base\\chatroom_app');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return File('${dir.path}\\input-diagnostics.log');
  }

  void _ensureOpen() {
    if (_sink != null || _opening) return;
    _opening = true;
    try {
      final f = _resolveFile();
      if (f == null) return;
      // 開檔前先看要不要輪替。**先檢查再開**——開了再檢查的話，
      // 這一輪的內容會寫進即將被改名的那份
      if (f.existsSync() && f.lengthSync() > _maxBytes) {
        final old = File('${f.path}.1');
        if (old.existsSync()) old.deleteSync();
        f.renameSync(old.path);
      }
      _file = f;
      _sink = f.openWrite(mode: FileMode.append);
      _write('session', {'started': DateTime.now().toIso8601String()});
    } catch (e) {
      // 診斷失敗不可以影響任何功能——但也不要靜靜吞掉
      debugPrint('input diagnostics 開檔失敗：$e');
      _sink = null;
    } finally {
      _opening = false;
    }
  }

  void _write(String kind, Map<String, Object?> data) {
    final sink = _sink;
    if (sink == null) return;
    final row = <String, Object?>{
      't': _since.elapsedMilliseconds,
      'at': DateTime.now().toIso8601String(),
      'kind': kind,
      ...data,
    };
    sink.writeln(row.entries.map((e) => '${e.key}=${e.value}').join(' '));
  }

  /// 記一筆。呼叫點都經過這裡，所以「開關關著就什麼都不做」只寫一次。
  void log(String kind, [Map<String, Object?> data = const {}]) {
    if (!enabled) return;
    _ensureOpen();
    _write(kind, data);
  }

  /// 焦點變了。**兩個都記**：`hasFocus` 與 `hasPrimaryFocus` 不一樣，
  /// 而「焦點在但打不出字」正是這個症狀的形狀——只記前者會看不出差別。
  void focus({required bool hasFocus, required bool hasPrimary}) =>
      log('focus', {'has': hasFocus, 'primary': hasPrimary});

  /// IME 組字狀態。**不記文字**，只記範圍與長度。
  ///
  /// `composing` 從有效變成無效的那一刻，就是「組字被打斷」——如果它與
  /// 某個事件在同一毫秒，那個事件就是嫌犯。
  void composing({
    required bool active,
    required int start,
    required int end,
    required int textLength,
    required int lines,
  }) =>
      log('composing', {
        'active': active,
        'start': start,
        'end': end,
        'len': textLength,
        'lines': lines,
      });

  /// App 前後景。「別的視窗跳出來搶焦點」那條唯一的抓手。
  void lifecycle(String state) => log('lifecycle', {'state': state});

  /// 工作列角標的 Win32 呼叫（`setOverlayIcon`）。
  ///
  /// 09/07 的實驗顯示它單獨不會造成卡住，但**時間軸上它是免費的參照點**：
  /// 下次發作時它在不在附近，一眼就看得出來。
  void badge(int count, {required bool before}) =>
      log('badge', {'n': count, 'phase': before ? 'before' : 'after'});

  Future<void> flush() async {
    try {
      await _sink?.flush();
    } catch (_) {
      // 關檔期間的失敗不值得處理——下一次寫入會重試
    }
  }

  /// 給測試看的落點。正式路徑由 [_resolveFile] 決定。
  @visibleForTesting
  String? get path => _file?.path;
}
