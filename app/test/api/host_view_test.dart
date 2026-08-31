import 'dart:typed_data';

import 'package:chatroom_app/api/api_client.dart';
import 'package:chatroom_app/ws/ws_protocol.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

class _Recorder implements HttpClientAdapter {
  final List<RequestOptions> seen = [];

  @override
  Future<ResponseBody> fetch(
      RequestOptions options, Stream<Uint8List>? _, Future<void>? _) async {
    seen.add(options);
    return ResponseBody.fromString('{"ok":true}', 200, headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    });
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  group('X-Host-View 只在開關打開時才帶', () {
    test('關著時不帶——持主 token 不等於隨時在用那個身分', () async {
      final rec = _Recorder();
      final dio = createApiDio(
          baseUrl: 'http://test', token: 't', hostView: () => false)
        ..httpClientAdapter = rec;
      await dio.get('/api/rooms');
      expect(rec.seen.single.headers.containsKey('X-Host-View'), isFalse);
    });

    test('開著時帶 1', () async {
      final rec = _Recorder();
      final dio = createApiDio(
          baseUrl: 'http://test', token: 't', hostView: () => true)
        ..httpClientAdapter = rec;
      await dio.get('/api/rooms');
      expect(rec.seen.single.headers['X-Host-View'], '1');
    });

    test('每次請求現讀，不是建 dio 時就定死——開關要能即時生效，'
        '而重建 dio 會把連線一起關掉', () async {
      final rec = _Recorder();
      var on = false;
      final dio = createApiDio(
          baseUrl: 'http://test', token: 't', hostView: () => on)
        ..httpClientAdapter = rec;
      await dio.get('/api/rooms');
      on = true;
      await dio.get('/api/rooms');
      expect(rec.seen[0].headers.containsKey('X-Host-View'), isFalse);
      expect(rec.seen[1].headers['X-Host-View'], '1');
    });

    test('沒給 hostView callback 的舊呼叫端不受影響', () async {
      final rec = _Recorder();
      final dio = createApiDio(baseUrl: 'http://test', token: 't')
        ..httpClientAdapter = rec;
      await dio.get('/api/rooms');
      expect(rec.seen.single.headers.containsKey('X-Host-View'), isFalse);
    });
  });

  group('WS 也要帶，否則主持人看得到歷史卻收不到新訊息', () {
    test('開著時 query 帶 host_view=1', () {
      final uri = WsProtocol.wsUri('http://h:8787', 'tok', hostView: true);
      expect(uri.queryParameters['host_view'], '1');
      expect(uri.queryParameters['token'], 'tok');
    });

    test('關著時完全不帶那個參數', () {
      final uri = WsProtocol.wsUri('http://h:8787', 'tok');
      expect(uri.queryParameters.containsKey('host_view'), isFalse);
    });

    test('https → wss，主持人參數不影響 scheme 推導', () {
      final uri = WsProtocol.wsUri('https://h', 'tok', hostView: true);
      expect(uri.scheme, 'wss');
    });
  });
}
