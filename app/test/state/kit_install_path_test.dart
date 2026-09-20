import 'dart:io';

import 'package:chatroom_app/state/kit_installer.dart';
import 'package:flutter_test/flutter_test.dart';

/// 安裝位置在**開始下載之前**就要判得出能不能用。
void main() {
  test('底下幾層還不存在沒關係——解壓時會建', () async {
    final root = Directory.systemTemp.createTempSync('kit-path');
    addTearDown(() => root.deleteSync(recursive: true));

    final target = '${root.path}${Platform.pathSeparator}a'
        '${Platform.pathSeparator}b';
    expect(await checkKitInstallPath(target), isNull);
    expect(Directory(target).existsSync(), isFalse,
        reason: '檢查不該順手把資料夾建起來');
  });

  test('留空與相對路徑各有各的理由', () async {
    expect(await checkKitInstallPath('  '), KitPathProblem.empty);
    expect(await checkKitInstallPath('hub-kit'), KitPathProblem.relative);
  });

  test('🔴 不存在的磁碟機：往下建幾層都沒有用', () async {
    final used = Directory(r'C:\').existsSync();
    if (!used) return; // 不是 Windows，這一題沒有意義
    final free = 'DEFGHIJKLMNOPQRSTUVWXYZ'
        .split('')
        .where((d) => !Directory('$d:\\').existsSync())
        .firstOrNull;
    if (free == null) return; // 這台機器每個代號都被佔著
    expect(await checkKitInstallPath('$free:\\UEP\\Chatroom'),
        KitPathProblem.missingRoot);
  });
}
