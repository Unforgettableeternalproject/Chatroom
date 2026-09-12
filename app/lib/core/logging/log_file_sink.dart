import 'dart:io';

/// 把 log 落成檔案。
///
/// `developer.log` 只有在接著 debugger／DevTools 時看得見——release build
/// 的 Windows GUI app 沒有 console，也沒有任何地方收得到它。後果不是
/// 「log 少了一點」，而是**「有寫 log」與「根本沒跑到那一行」在使用者手上
/// 長得一模一樣**：09/12 追 Codex 轉送為什麼沒喚醒時，
/// `_log.info('mention 補投成功…')`、`_log.warning('mention 補投逾時放棄…')`
/// 這些專門為了讓人看見失效而寫的訊息，一則都調不出來，只能靠推理收案。
class LogFileSink {
  LogFileSink(this.directory, {this.maxBytes = 2 * 1024 * 1024});

  final Directory directory;

  /// 超過就換檔。診斷用途，留兩份（現行 + `.1`）夠回溯一次啟動。
  final int maxBytes;

  static const fileName = 'chatroom-app.log';

  File get file => File('${directory.path}${Platform.pathSeparator}$fileName');
  File get previous => File('${file.path}.1');

  /// 落檔失敗只講一次——log 壞掉本身不值得再用 log 洗版。
  bool _warned = false;

  void write(String line) {
    try {
      if (!directory.existsSync()) directory.createSync(recursive: true);
      _rotateIfNeeded();
      // append，不是覆寫：以 truncate 開檔失敗時留下的是 0 bytes，
      // 而這個檔案存在的唯一理由就是事後回去讀它。
      file.writeAsStringSync('$line\n', mode: FileMode.append, flush: true);
    } catch (e) {
      if (_warned) return;
      _warned = true;
      stderr.writeln('log 落檔失敗（之後不再重複告知）：$e');
    }
  }

  void _rotateIfNeeded() {
    if (!file.existsSync() || file.lengthSync() < maxBytes) return;
    // rename 而不是清空：換檔的那一瞬間若出事，舊的那份仍然完整
    if (previous.existsSync()) previous.deleteSync();
    file.renameSync(previous.path);
  }
}

/// 預設落檔位置。取不到就回 `null`——**不落檔好過寫進工作目錄**，
/// 那會隨著啟動方式跑到不同地方，找的人反而更難找。
Directory? defaultLogDirectory([Map<String, String>? env]) {
  final e = env ?? Platform.environment;
  String? pick(List<String> names) {
    for (final n in names) {
      final v = e[n];
      if (v != null && v.isNotEmpty) return v;
    }
    return null;
  }

  if (Platform.isWindows) {
    final base = pick(['LOCALAPPDATA', 'APPDATA']);
    // 不用字面反斜線：Dart 裡 backslash-U 之類不是合法跳脫，會被靜靜吃掉
    return base == null
        ? null
        : Directory(
            [base, 'UEP', 'Chatroom', 'logs'].join(Platform.pathSeparator),
          );
  }
  if (Platform.isMacOS) {
    final home = pick(['HOME']);
    return home == null ? null : Directory('$home/Library/Logs/UEP-Chatroom');
  }
  final state = pick(['XDG_STATE_HOME']);
  if (state != null) return Directory('$state/uep-chatroom');
  final home = pick(['HOME']);
  return home == null ? null : Directory('$home/.local/state/uep-chatroom');
}
