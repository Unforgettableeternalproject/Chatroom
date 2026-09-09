import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/host_kit.dart';

/// 註冊檔的位置。`host-kit/install.py` 寫，App 讀。
///
/// 拿不到家目錄時回 null——那時就是「這台沒有 Hub」，不是錯誤。
File? hostKitRegistryFile() {
  final home = Platform.environment['USERPROFILE'] ??
      Platform.environment['HOME'] ??
      '';
  if (home.isEmpty) return null;
  return File('$home${Platform.pathSeparator}.chatroom'
      '${Platform.pathSeparator}host-kit.json');
}

/// 這台機器上有沒有裝 Hub 主持包。
///
/// **`null` 是正常狀態，不是錯誤。** 絕大多數使用者是成員不是主持人，
/// 他們的機器上本來就沒有這包——那時「主機」入口**整個不存在**，
/// 不是變灰。一個永遠按不動的入口比沒有這個功能更糟。
///
/// 解析失敗也回 `null`：一個壞掉的指路牌與沒有指路牌，對使用者的意義相同
/// （App 幫不上忙），而把它畫成「Hub 壞了」會讓人跑去修一個沒有壞的伺服器。
final hostKitProvider = FutureProvider<HostKit?>((ref) async {
  final file = hostKitRegistryFile();
  if (file == null) return null;
  try {
    if (!await file.exists()) return null;
    final raw = await file.readAsString();
    final json = jsonDecode(raw);
    if (json is! Map) return null;
    final kit = HostKit.fromJson(json.cast<String, dynamic>());
    if (kit.kitRoot.isEmpty) return null;
    // 註冊檔還在、但那包已經被搬走或刪掉——**指路牌指向不存在的地方，
    // 與沒有指路牌是同一件事**，不要顯示一個什麼都做不了的分頁
    if (!await Directory(kit.kitRoot).exists()) return null;
    return kit;
  } on Object {
    return null;
  }
});

/// Hub 現在的設定，從 `server/.env` **現讀**。
///
/// 不快取跨 session：主持人改完 `.env` 會期待畫面跟著變，而那正是他改它的
/// 理由。要重讀就 invalidate 這個 provider。
final hostEnvProvider = FutureProvider<HostEnv?>((ref) async {
  final kit = await ref.watch(hostKitProvider.future);
  if (kit == null) return null;
  final file = File(kit.envFile);
  try {
    if (!await file.exists()) return null;
    final values = <String, String>{};
    for (final line in await file.readAsLines()) {
      final text = line.trim();
      if (text.isEmpty || text.startsWith('#')) continue;
      final at = text.indexOf('=');
      if (at <= 0) continue;
      // 值裡可能有 `=`（token 是 urlsafe base64，會有 `-` 與 `_`，但別的
      // 欄位未必），所以只切第一個
      values[text.substring(0, at).trim()] =
          text.substring(at + 1).trim();
    }
    return HostEnv(
      host: values['CHATROOM_HOST'] ?? '',
      port: values['CHATROOM_PORT'] ?? '',
      token: values['CHATROOM_TOKEN'] ?? '',
    );
  } on Object {
    return null;
  }
});
