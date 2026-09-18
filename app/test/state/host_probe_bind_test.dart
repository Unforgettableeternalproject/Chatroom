import 'dart:io';

import 'package:chatroom_app/models/host_kit.dart';
import 'package:chatroom_app/state/host_kit_providers.dart';
import 'package:chatroom_app/state/host_probe.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// 三盞燈**探測打哪個位址**。
///
/// 🔴 這一層在 2026-09-15 之前一行測試都沒有：golden 與回饋測試都是把造好
/// 的 `HostHealth` 塞進 provider，繞過了探測本身。於是一個「照安裝器的建議
/// 把 `CHATROOM_HOST` 填成 VPN 介面 IP，三盞燈就全滅」的缺陷活了下來，
/// 而 Hub 好好的——連帶讓「啟動 Hub」永遠等不到成功（它的判準就是①燈）。
///
/// 重現手法：**把假 Hub 綁在 `127.0.0.2`**。那是迴環網段裡的另一個位址，
/// 從 `127.0.0.2` 打得到、從 `127.0.0.1` 打不到（已實測），與「綁在 VPN
/// 介面」是同一個形狀，但不需要真的有一張 VPN 介面才能跑這條測試。
void main() {
  late HttpServer server;
  late String port;
  const token = 'tok-for-test';

  Future<void> serve(String address) async {
    server = await HttpServer.bind(address, 0);
    port = '${server.port}';
    server.listen((req) async {
      if (req.uri.path == '/api/rooms') {
        // 認證燈打的是這一支。**token 對不對與位址對不對是兩件事**，
        // 混在一起的話，一個打錯位址的探測會顯示成「token 不被接受」，
        // 而主持人會去換一把沒有壞的鑰匙。
        req.response.statusCode =
            req.headers.value('Authorization') == 'Bearer $token' ? 200 : 401;
      } else {
        req.response.statusCode = 200;
      }
      await req.response.close();
    });
  }

  tearDown(() async => server.close(force: true));

  ProviderContainer containerFor(String host) => ProviderContainer(overrides: [
        hostEnvProvider.overrideWith(
            (ref) async => HostEnv(host: host, port: port, token: token)),
      ]);

  test('🔴 綁在單一介面時要打那個位址，不是迴環', () async {
    await serve('127.0.0.2');
    final c = containerFor('127.0.0.2');
    addTearDown(c.dispose);

    final health = (await c.read(hostHealthProvider.future))!;

    expect(health.process.state, ProbeState.ok,
        reason: 'Hub 活著。bind 到特定位址就只收那個位址的連線，迴環不在'
            '監聽清單裡——打 127.0.0.1 會連不到，而那不代表進程死了');
    expect(health.auth.state, ProbeState.ok,
        reason: '認證燈打的必須是同一個位址。打不到的位址回 null，'
            '會被畫成「token 不被接受」——指向一個沒有壞的東西');
  });

  test('🔴 綁單一介面時，②不再獨立探測，而且要說出來', () async {
    await serve('127.0.0.2');
    final c = containerFor('127.0.0.2');
    addTearDown(c.dispose);

    final health = (await c.read(hostHealthProvider.future))!;

    expect(health.reachable.state, ProbeState.ok);
    expect(health.reachable.detail, contains('127.0.0.2'));
  });

  test('綁 0.0.0.0 時仍走迴環，而②是 unknown 不是綠燈', () async {
    await serve('0.0.0.0');
    final c = containerFor('0.0.0.0');
    addTearDown(c.dispose);

    final health = (await c.read(hostHealthProvider.future))!;

    expect(health.process.state, ProbeState.ok);
    expect(health.reachable.state, ProbeState.unknown,
        reason: '所有介面都收時本機這一關必然過，給綠燈等於給一個沒有內容'
            '的保證——防火牆對外放行了沒，這台機器驗不到');
  });

  test('🔴 .env 沒寫 CHATROOM_HOST 時跟著 Hub 的預設走（127.0.0.1）', () async {
    await serve('127.0.0.1');
    final c = containerFor('');
    addTearDown(c.dispose);

    final health = (await c.read(hostHealthProvider.future))!;

    expect(health.process.state, ProbeState.ok,
        reason: 'host 空字串會讓 URL 變成 http://:8787——那必定連不上，'
            '而且錯得看不出來。server 端 config.py 的預設是 127.0.0.1');
  });

  test('Hub 真的沒在跑時，①是紅燈而後兩盞是 unknown', () async {
    await serve('127.0.0.1');
    final dead = '${server.port}';
    await server.close(force: true);
    // 關掉之後再起一個佔位的，讓 tearDown 有東西可關
    server = await HttpServer.bind('127.0.0.1', 0);

    final c = ProviderContainer(overrides: [
      hostEnvProvider.overrideWith(
          (ref) async => HostEnv(host: '127.0.0.1', port: dead, token: token)),
    ]);
    addTearDown(c.dispose);

    final health = (await c.read(hostHealthProvider.future))!;

    expect(health.process.state, ProbeState.bad);
    expect(health.reachable.state, ProbeState.unknown,
        reason: '它們沒有被否定，只是還輪不到。一起畫紅會讓人以為有三個'
            '問題要修，其實只有一個');
    expect(health.auth.state, ProbeState.unknown);
  });
}
