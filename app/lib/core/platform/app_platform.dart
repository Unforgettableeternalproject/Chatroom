import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 桌面三平台。手機與 Web 不在內（偵測回 `null`）。
///
/// 路徑、命令與腳本的組裝都吃這個值而不是直接讀 `Platform`：測試跑在
/// Windows 上，`Platform.isWindows` 是跑測試那台機器的事實，不是被測條件，
/// 不注入的話 macOS／Linux 那幾條分支永遠測不到。
enum AppPlatform {
  windows,
  macos,
  linux;

  bool get isPosix => this != AppPlatform.windows;

  /// 這個平台的路徑分隔。**不讀 `Platform.pathSeparator`**——被測的平台
  /// 不一定是跑測試的那一個。
  String get sep => isPosix ? '/' : r'\';

  String join(Iterable<String> parts) => parts.join(sep);
}

/// 目前這台機器的平台；不是桌面三者就回 `null`。
AppPlatform? detectAppPlatform() {
  if (kIsWeb) return null;
  if (Platform.isWindows) return AppPlatform.windows;
  if (Platform.isMacOS) return AppPlatform.macos;
  if (Platform.isLinux) return AppPlatform.linux;
  return null;
}

/// 平台的唯一入口。測試覆寫它來扮演另一個平台。
final appPlatformProvider =
    Provider<AppPlatform?>((ref) => detectAppPlatform());

/// 使用者家目錄。Windows 先看 `USERPROFILE`，POSIX 先看 `HOME`。
/// 都沒有回空字串。
String userHomeDir({AppPlatform? platform, Map<String, String>? environment}) {
  final env = environment ?? Platform.environment;
  final p = platform ?? detectAppPlatform();
  final order = p != null && p.isPosix
      ? const ['HOME', 'USERPROFILE']
      : const ['USERPROFILE', 'HOME'];
  for (final key in order) {
    final v = env[key];
    if (v != null && v.isNotEmpty) return v;
  }
  return '';
}

/// `~/.chatroom/<name>`：各包安裝器寫的註冊檔。拿不到家目錄回 `null`。
File? chatroomRegistryFile(String name,
    {AppPlatform? platform, Map<String, String>? environment}) {
  final home = userHomeDir(platform: platform, environment: environment);
  if (home.isEmpty) return null;
  final sep = platform?.sep ?? Platform.pathSeparator;
  return File('$home$sep.chatroom$sep$name');
}

/// 安裝根目錄：kit 解壓位置、執行器狀態、自更新暫存都在它底下。
///
/// 與 Python 端的同名規則是**同一個契約**（`scripts/service.py`
/// 的 `install_root()`、`chatroom_runner.config.default_install_root()`、
/// `runner-kit/install.py`）：
///
/// - Windows：`%LOCALAPPDATA%\UEP\Chatroom`
/// - macOS：`~/Library/Application Support/UEP/Chatroom`
/// - Linux：`${XDG_DATA_HOME:-~/.local/share}/uep/chatroom`
///   （`XDG_DATA_HOME` 不是絕對路徑時依 XDG 規範視為無效）
///
/// Windows 保留原本的行為：沒有 `LOCALAPPDATA` 時退到
/// `<家目錄>\.chatroom\kits`。[platform] 省略時看這台機器；偵測不到
/// （手機、Web）也走 Windows 那條，等同這個函式引入前的行為。
/// 推不出來回空字串。
String chatroomInstallRoot(
    {AppPlatform? platform, Map<String, String>? environment}) {
  final env = environment ?? Platform.environment;
  final p = platform ?? detectAppPlatform();
  if (p == null || p == AppPlatform.windows) {
    final sep = p?.sep ?? Platform.pathSeparator;
    final local = env['LOCALAPPDATA'] ?? '';
    if (local.isNotEmpty) return [local, 'UEP', 'Chatroom'].join(sep);
    final home = userHomeDir(platform: p, environment: env);
    if (home.isEmpty) return '';
    return [home, '.chatroom', 'kits'].join(sep);
  }
  final home = env['HOME'] ?? '';
  if (p == AppPlatform.macos) {
    if (home.isEmpty) return '';
    return [home, 'Library', 'Application Support', 'UEP', 'Chatroom']
        .join('/');
  }
  final xdg = env['XDG_DATA_HOME'] ?? '';
  if (xdg.startsWith('/')) return [xdg, 'uep', 'chatroom'].join('/');
  if (home.isEmpty) return '';
  return [home, '.local', 'share', 'uep', 'chatroom'].join('/');
}
