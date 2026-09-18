import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'host_kit_providers.dart';

/// 一盞燈的狀態。
///
/// 🔴 **`unknown` 不是 `bad` 的委婉說法，是第三種答案。**
///
/// 有些事情從 Hub 這台機器上**驗不到**——防火牆對外放行了沒、隧道網址從
/// 外面連不連得進來。把驗不到畫成紅燈就是製造假警報，而假警報比沒有燈更糟：
/// 主持人會跑去修一個沒有壞的東西，然後在下一次真的壞掉時不再相信這盞燈。
enum ProbeState { checking, ok, bad, unknown }

@immutable
class Probe {
  const Probe(this.state, this.detail, {this.caveat = ''});

  const Probe.checking() : this(ProbeState.checking, '檢查中…');

  final ProbeState state;

  /// 一句話講「現在是什麼情況」。
  final String detail;

  /// 一句話講「這個檢查**沒有**證明什麼」。
  ///
  /// 綠燈也可能需要它——「本機打得到」不等於「別台機器連得到」，而那個落差
  /// 正是主持人最常撞、也最難自己想到的一關。
  final String caveat;
}

/// 三盞燈。
///
/// 「成員連不上」是一個症狀，底下是三件**彼此獨立、症狀相同、處置完全不同**
/// 的事。合成一盞燈的話，主持人只能從頭試一遍。
@immutable
class HostHealth {
  const HostHealth({
    required this.process,
    required this.reachable,
    required this.auth,
  });

  /// ① Hub 進程活著嗎（本機 127.0.0.1）。
  final Probe process;

  /// ② 綁定位址打得通嗎（綁對介面了沒）。
  final Probe reachable;

  /// ③ token 對不對。
  final Probe auth;
}

/// 打一次 health，只回「通了沒」。
///
/// 抽出來給隧道那邊共用——**探測邏輯只能有一份**：兩邊各寫一次的話，
/// 逾時長短、要不要跟隨轉址這種細節會慢慢分岔，而分岔之後同一台 Hub
/// 在兩個地方會顯示成不同的狀態，沒有人看得出哪個是對的。
Future<bool> probeHealth(String url) async => await _get(url) == 200;

/// 打一次並回狀態碼；連不到回 null。
///
/// 與 [probeHealth] 共用同一個 `_get`——探測邏輯只能有一份。
Future<int?> probeStatus(String url, {String? token}) =>
    _get(url, token: token);

/// 打一次，回狀態碼；連不到（拒絕連線、逾時、DNS 解不出）回 null。
///
/// 🔴 **只回狀態碼，不回 body。** 原本這裡回的是狀態碼與 body 用一個 NUL
/// 黏起來的字串，再由 `_statusOf` 切回來——而那個 body **從來沒有任何
/// 呼叫端讀過**。代價卻很實在：那兩個 NUL 讓 git 把這支 `.dart` 原始碼
/// 判成二進位檔，`git diff` 與 PR review 一律只顯示「Binary files
/// differ」，看不到改了什麼，merge 衝突時也只能整檔二選一
/// （2026-09-15 發現）。
Future<int?> _get(String url, {String? token}) async {
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 2);
  try {
    final req = await client.getUrl(Uri.parse(url));
    if (token != null && token.isNotEmpty) {
      req.headers.set('Authorization', 'Bearer $token');
    }
    final res = await req.close().timeout(const Duration(seconds: 3));
    // body 仍然要排掉——不讀完的話連線不會歸還，接下來幾次探測會排隊等到
    // 逾時，而那看起來會像「Hub 變慢了」，不像探測自己的問題。
    await res.drain<void>();
    return res.statusCode;
  } on Object {
    return null;
  } finally {
    client.close(force: true);
  }
}

/// 探這台機器上的 Hub。
///
/// 三盞燈**依序**探但各自獨立回報：進程死著的時候後兩盞是 `unknown` 而不是
/// `bad`——它們沒有被否定，只是還輪不到它們。把它們一起畫紅會讓主持人以為
/// 有三個問題要修，其實只有一個。
final hostHealthProvider = FutureProvider<HostHealth?>((ref) async {
  final env = await ref.watch(hostEnvProvider.future);
  if (env == null || !env.isComplete) return null;

  const blocked = Probe(ProbeState.unknown, '等 Hub 啟動');

  // 探測要打哪個位址。
  //
  // 🔴 原本①與③寫死 `127.0.0.1`，理由寫成「綁在 VPN 介面時本機仍然
  // 連得到迴環」——**那句宣稱是錯的**。TCP bind 到特定位址就只收那個
  // 位址的連線，迴環不在監聽清單裡（2026-09-15 實測：綁 26.176.231.43
  // 時 127.0.0.1:8787 直接拒絕連線）。而安裝器 `--host` 的說明建議填 VPN
  // 介面 IP，所以**照建議做的人三盞燈全滅，而 Hub 好好的**。
  //
  // 綁 `0.0.0.0` 時迴環仍然是對的選擇——它把「進程活著」與「綁對介面」分開，
  // 那正是三盞燈存在的理由。綁單一介面時那兩件事**本來就分不開**：只有一個
  // 位址可打。那時不要假裝驗了兩次，caveat 要講明白。
  //
  // host 為空＝`.env` 沒寫 `CHATROOM_HOST`，Hub 那邊的預設是 `127.0.0.1`
  // （`server/chatroom_server/config.py`）。這裡跟著它，不要讓 URL 變成
  // `http://:8787` 那種必定連不上、而且錯得看不出來的東西。
  final bindHost = env.host.isEmpty ? '127.0.0.1' : env.host;
  final probeHost = env.bindsAllInterfaces ? '127.0.0.1' : bindHost;

  // ① 進程：打得到就代表進程活著。
  final local = await _get('http://$probeHost:${env.port}/api/health');
  if (local != 200) {
    return HostHealth(
      process: const Probe(ProbeState.bad, '已停止'),
      reachable: blocked,
      auth: blocked,
    );
  }
  const process = Probe(ProbeState.ok, '執行中');

  // ② 綁定位址：綁 0.0.0.0 時所有介面都收，本機這一關必然過，沒有意義——
  // 那時要講的是「別台機器連不連得到我驗不到」，而不是給一個沒有內容的綠燈
  final Probe reachable;
  if (env.bindsAllInterfaces) {
    reachable = const Probe(ProbeState.unknown, '綁在所有介面（0.0.0.0）');
  } else {
    // ①打的就是這個位址（綁單一介面時迴環不可達，只有它能打），所以這裡
    // **不再打第二次**。再打一次不會多知道任何事，卻會多一種失敗方式：
    // 兩次探測之間 Hub 剛好停掉時，畫面會變成「進程活著、但綁定位址打不通」
    // ——一個自相矛盾、而且指不出該修什麼的狀態。
    reachable = Probe(ProbeState.ok, '$bindHost 打得通');
  }

  // ③ token：拿 .env 這份去打一個要認證的端點。401 就是這份不對——
  // 而那多半表示發出去的那份與這裡不一樣，不是 token 壞了
  final code =
      await _get('http://$probeHost:${env.port}/api/rooms', token: env.token);
  final Probe auth;
  if (code == 200) {
    auth = const Probe(ProbeState.ok, '通過');
  } else if (code == 401 || code == 403) {
    auth = const Probe(ProbeState.bad, 'token 不被接受');
  } else {
    auth = const Probe(ProbeState.unknown, '驗不出來');
  }

  return HostHealth(process: process, reachable: reachable, auth: auth);
});
