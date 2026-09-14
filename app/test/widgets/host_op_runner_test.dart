import 'package:chatroom_app/screens/host/host_console_screen.dart';
import 'package:flutter_test/flutter_test.dart';

/// `runOp` —— 「送出一個 detached 動作，然後盯著狀態」的決策部分。
///
/// 這裡每一條對應一個實際發生過、而且**不會出聲**的缺陷。它們原本全部只
/// 活在 widget 樹裡，只能靠註解宣稱做到了（審核用Codex 09/14 終審：
/// 「這些正是本批三個行為修正，不能只靠註解」）。
void main() {
  Future<void> noGap() async {}

  group('ready() 拋不能讓它永遠停在 pending', () {
    test('🔴 每一次都拋 ⇒ 走到逾時，不是卡住、也不是把例外丟出去', () async {
      var launched = 0;
      final r = await runOp(
        kind: 'hub_start',
        launch: () async => launched++,
        ready: (_) async => throw StateError('provider 炸了'),
        okText: '起來了',
        timeoutText: '還沒起來',
        tries: 3,
        gap: noGap,
      );
      expect(launched, 1);
      expect(r['detail'], '還沒起來');
      expect(r['ok'], isTrue, reason: '逾時不是失敗——進程可能正要起來');
      expect(r.containsKey('pending'), isFalse);
    });

    test('前幾次拋、後來成功 ⇒ 算成功（啟動中 health 本來就可能拋）', () async {
      var n = 0;
      final r = await runOp(
        kind: 'hub_start',
        launch: () async {},
        ready: (_) async {
          n++;
          if (n < 3) throw StateError('還沒起來');
          return true;
        },
        okText: '起來了',
        timeoutText: '還沒起來',
        tries: 5,
        gap: noGap,
      );
      expect(r['detail'], '起來了');
    });
  });

  group('本來就好了 ⇒ 不送出', () {
    test('🔴 Hub 已在跑：不呼叫 launch，而且不說「起來了」', () async {
      var launched = 0;
      final r = await runOp(
        kind: 'hub_start',
        alreadyDone: () async => true,
        alreadyText: '本來就在跑',
        launch: () async => launched++,
        ready: (_) async => true,
        okText: '起來了',
        timeoutText: '還沒起來',
        gap: noGap,
      );
      expect(launched, 0, reason: '再送一次就是第二個 Hub 進程');
      expect(r['detail'], '本來就在跑');
      expect(r['detail'], isNot('起來了'),
          reason: '「現在是 ok」不等於「這次動作成功」');
    });

    test('沒在跑 ⇒ 照常送出', () async {
      var launched = 0;
      final r = await runOp(
        kind: 'hub_start',
        alreadyDone: () async => false,
        alreadyText: '本來就在跑',
        launch: () async => launched++,
        ready: (_) async => true,
        okText: '起來了',
        timeoutText: '還沒起來',
        gap: noGap,
      );
      expect(launched, 1);
      expect(r['detail'], '起來了');
    });

    test('🔴 前置檢查自己拋 ⇒ 什麼都不做，並且說出來', () async {
      // 這一條原本釘的是相反的行為（「當作沒好，照常送出」），而那把原本
      // 的缺陷原樣放回來：Hub 其實在跑、只是 health 這一瞬間讀不到 ⇒
      // 送出第二個進程 ⇒ 下一輪 health 恢復，輪詢看到那個本來就在的 Hub
      // ⇒ 回報本次成功。兩個錯合起來看起來完全正常（審核用Codex 09/14）
      var launched = 0;
      final r = await runOp(
        kind: 'hub_start',
        alreadyDone: () async => throw StateError('health 讀不到'),
        alreadyText: '本來就在跑',
        launch: () async => launched++,
        ready: (_) async => true,
        okText: '起來了',
        timeoutText: '還沒起來',
        gap: noGap,
      );
      expect(launched, 0, reason: '不確定它在不在跑的時候送出，就是在賭');
      expect(r['ok'], isFalse);
      expect('${r['error']}', contains('沒有送出'));
      expect(r['detail'], isNot('起來了'));
    });
  });

  group('launch 自己拋 ⇒ 回失敗，不要輪詢一個沒送出去的東西', () {
    test('錯誤訊息要留著', () async {
      var polled = 0;
      final r = await runOp(
        kind: 'tunnel_start',
        launch: () async => throw StateError('腳本不見了'),
        ready: (_) async {
          polled++;
          return true;
        },
        okText: '開好了',
        timeoutText: '還沒好',
        gap: noGap,
      );
      expect(r['ok'], isFalse);
      expect('${r['error']}', contains('腳本不見了'));
      expect(polled, 0);
    });
  });

  group('隧道：殘留的舊網址不能算成功', () {
    // .tunnel-url 會殘留（視窗被強制關掉、當機、斷電時 finally 不執行）。
    // 拿「有網址」當成功條件的話，一條死掉的隧道會讓畫面說「開好了」，
    // 然後主持人把那個網址發給所有人
    Future<Map<String, dynamic>> openTunnel({
      required String before,
      required List<String> probes,
    }) {
      var i = 0;
      return runOp(
        kind: 'tunnel_start',
        launch: () async {},
        ready: (_) async {
          final now = i < probes.length ? probes[i] : probes.last;
          i++;
          return now.isNotEmpty && now != before;
        },
        okText: '隧道開了',
        timeoutText: '還沒換成新的',
        tries: 3,
        gap: noGap,
      );
    }

    test('🔴 網址從頭到尾是同一條（殘留）⇒ 不算成功', () async {
      final r = await openTunnel(
        before: 'https://old.trycloudflare.com',
        probes: ['https://old.trycloudflare.com'],
      );
      expect(r['detail'], '還沒換成新的');
    });

    test('換成另一條 ⇒ 成功', () async {
      final r = await openTunnel(
        before: 'https://old.trycloudflare.com',
        probes: [
          'https://old.trycloudflare.com',
          'https://new.trycloudflare.com',
        ],
      );
      expect(r['detail'], '隧道開了');
    });

    test('本來沒有網址、後來有了 ⇒ 成功', () async {
      final r = await openTunnel(before: '', probes: ['', 'https://a.b']);
      expect(r['detail'], '隧道開了');
    });
  });

  group('快照（baseline）', () {
    test('🔴 baseline 拋 ⇒ 不 launch、回錯誤，而且訊息是給人看的', () async {
      var launched = 0;
      final r = await runOp(
        kind: 'tunnel_start',
        baseline: () async => throw StateError('讀不到 .tunnel-url'),
        baselineFailText: '查不到現在的隧道狀態，所以沒有送出任何指令',
        launch: () async => launched++,
        ready: (_) async => true,
        okText: '隧道開了',
        timeoutText: '還沒換成新的',
        gap: noGap,
      );
      expect(launched, 0, reason: '快照答不出來就送出，等於在賭下一輪讀到的是新的');
      expect(r['ok'], isFalse);
      expect('${r['error']}', contains('沒有送出任何指令'));
      expect('${r['error']}', contains('讀不到 .tunnel-url'),
          reason: '原始錯誤要留著，不然沒人查得下去');
    });

    test('🔴 baseline 在 launch 之前取，而且 ready 收到的就是它', () async {
      // 順序錯的話會拿「已經開始開隧道之後」的狀態當基準，那時網址可能
      // 已經換了 ⇒ 基準與結果是同一個東西 ⇒ 永遠判不出變化
      final order = <String>[];
      String? seen;
      await runOp(
        kind: 'tunnel_start',
        baseline: () async {
          order.add('baseline');
          return 'https://old.example';
        },
        launch: () async => order.add('launch'),
        ready: (base) async {
          order.add('ready');
          seen = base;
          return true;
        },
        okText: '隧道開了',
        timeoutText: '還沒換成新的',
        gap: noGap,
      );
      expect(order, ['baseline', 'launch', 'ready']);
      expect(seen, 'https://old.example');
    });

    test('alreadyDone 先於 baseline：本來就好了就不必取快照', () async {
      var baselineCalls = 0;
      final r = await runOp(
        kind: 'hub_start',
        alreadyDone: () async => true,
        alreadyText: '本來就在跑',
        baseline: () async {
          baselineCalls++;
          return '';
        },
        launch: () async {},
        ready: (_) async => true,
        okText: '起來了',
        timeoutText: '還沒起來',
        gap: noGap,
      );
      expect(baselineCalls, 0);
      expect(r['detail'], '本來就在跑');
    });
  });
}
