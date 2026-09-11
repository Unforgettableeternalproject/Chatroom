import 'dart:async';

import 'package:chatroom_app/screens/settings/settings_screen.dart';
import 'package:chatroom_app/ws/ws_client.dart';
import 'package:flutter_test/flutter_test.dart';

/// 「測試連線」的 WS 那一半。
///
/// 這顆按鈕原本只打 REST，而 App 的即時通道走 WS——**兩條路徑的認證是分開
/// 實作的**，而且分歧過兩次（08-29 的 access_token、09-07 的人類憑證），
/// 兩次都是「REST 收、WS 不收」。
///
/// 那種狀態下按鈕會說「連線成功」、App 進去之後一直重連，而使用者看到的是
/// 「設定明明是對的」。2026-09-12 艾斯維爾實際撞到：測試連線顯示
/// `連線成功 · hub 1.2.1 · 0 個房間`，App 卻停在「重連中」。
class _FakeConnection implements WsConnection {
  bool closed = false;

  @override
  Stream<dynamic> get stream => const Stream.empty();

  @override
  void send(String data) {}

  @override
  Future<void> close() async => closed = true;

  @override
  int? get closeCode => null;
}

void main() {
  const url = 'http://127.0.0.1:8799';
  const token = 'whatever';

  test('握手成功回 null', () async {
    final conn = _FakeConnection();
    final result = await probeWebSocket(url, token,
        connector: (_) async => conn);

    expect(result, isNull);
    // 探測用的連線要關掉——留著等於每按一次測試連線就多一條
    expect(conn.closed, isTrue);
  });

  test('🔴 4401 要講「REST 通了但 WS 拒絕憑證」', () async {
    final result = await probeWebSocket(url, token,
        connector: (_) async => throw Exception('WebSocketChannelException 4401'));

    expect(result, isNotNull);
    // 這是整條修正的重點：**不可以只說「連線失敗」**。那會讓人回去檢查
    // 網址與 token，而那兩樣剛剛才被 REST 證明是對的
    expect(result, contains('REST 通了'));
    expect(result, contains('4401'));
    expect(result, contains('CHATROOM_HUMAN_TOKEN'));
  });

  test('逾時要講是 WS 這條路徑', () async {
    final result = await probeWebSocket(
      url, token,
      timeout: const Duration(milliseconds: 30),
      connector: (_) => Completer<WsConnection>().future, // 永遠不完成
    );

    expect(result, isNotNull);
    expect(result, contains('REST 通了'));
    expect(result, contains('WebSocket'));
  });

  test('其他錯誤也要保留「REST 通了」這個前提', () async {
    final result = await probeWebSocket(url, token,
        connector: (_) async => throw Exception('SocketException: refused'));

    expect(result, isNotNull);
    expect(result, contains('REST 通了'));
    // 沒有 4401 就不要亂指憑證——把人送去換 token 而問題在網路，
    // 比不講還糟
    expect(result, isNot(contains('CHATROOM_HUMAN_TOKEN')));
  });

  test('每一種失敗都說得出「問題在 WS 這條路徑」', () async {
    final failures = <Object>[
      Exception('WebSocketChannelException 4401'),
      Exception('SocketException: refused'),
      Exception('403'),
    ];
    for (final failure in failures) {
      final result = await probeWebSocket(url, token,
          connector: (_) async => throw failure);
      expect(result, isNotNull, reason: '$failure 應該回一句話');
      expect(result, contains('REST 通了'), reason: '$failure 漏了前提');
    }
  });
}
