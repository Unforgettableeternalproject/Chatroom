import 'dart:io';

import 'package:chatroom_app/state/kit_installer.dart';

/// 安裝流程的假網路與假子進程。**不打真網路、不跑真的 python**。
///
/// 它記下兩件事：`Expand-Archive` 把東西解到哪，以及 `install.py` 收到哪些
/// 參數。「安裝位置」這個功能要驗的就是這兩處收到同一個位置。
class FakeKitBackend implements KitHttpClient, KitProcessRunner {
  /// 解壓的目的地（`-DestinationPath`）。沒解過是 `null`。
  String? extractedTo;

  /// 被呼叫的 `install.py` 的完整路徑。
  String? installScript;

  /// `install.py` 之後的那一串參數。
  List<String> installArgs = const [];

  @override
  Future<(int, Object?)> getJson(String url) async => (404, null);

  @override
  Future<void> download(
    String url,
    String savePath, {
    void Function(int received, int total)? onProgress,
  }) async {
    final file = File(savePath);
    await file.parent.create(recursive: true);
    await file.writeAsString('zip');
    onProgress?.call(1, 1);
  }

  @override
  Future<ProcessResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
  }) async {
    if (arguments.contains('--version')) {
      return ProcessResult(0, 0, 'Python 3.12.7', '');
    }
    if (executable == 'powershell') {
      final dest = RegExp(r'-DestinationPath "([^"]+)"')
          .firstMatch(arguments.join(' '))
          ?.group(1);
      extractedTo = dest;
      if (dest != null) {
        // 安裝器要找得到 `install.py`，否則走不到下一步
        await File('$dest${Platform.pathSeparator}install.py')
            .writeAsString('# fake');
      }
      return ProcessResult(0, 0, '', '');
    }
    final at = arguments.indexWhere((a) => a.endsWith('install.py'));
    if (at >= 0) {
      installScript = arguments[at];
      installArgs = arguments.sublist(at + 1);
      return ProcessResult(
        0,
        0,
        'RESULT {"ok": true, "version": "1.2.3"}',
        '',
      );
    }
    return ProcessResult(0, 0, '', '');
  }
}
