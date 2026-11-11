import 'dart:typed_data';

import 'package:chatroom_app/api/api_client.dart';
import 'package:chatroom_app/core/host_reason.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

class _CaptureAdapter implements HttpClientAdapter {
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    requests.add(options);
    return ResponseBody.fromString('{}', 200, headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    });
  }

  @override
  void close({bool force = false}) {}
}

/// 主持人操作的理由：只在主持人模式、寫入請求、有理由時才進 body／query。
void main() {
  Dio build({required bool host, required _CaptureAdapter adapter}) {
    final dio = createApiDio(
        baseUrl: 'http://hub.test', token: 't', hostView: () => host);
    dio.httpClientAdapter = adapter;
    return dio;
  }

  test('主持人模式＋理由：POST body 帶 reason，原有欄位保留', () async {
    final a = _CaptureAdapter();
    final dio = build(host: true, adapter: a);
    await runWithHostReason('違反規則', () => dio.post('/x', data: {'approve': true}));
    expect(a.requests.single.data, {'approve': true, 'reason': '違反規則'});
  });

  test('POST 沒有 body 時也補上 {reason}', () async {
    final a = _CaptureAdapter();
    final dio = build(host: true, adapter: a);
    await runWithHostReason('清理', () => dio.post('/archive'));
    expect(a.requests.single.data, {'reason': '清理'});
  });

  test('body 已有非空 reason 不蓋掉；空的 reason 會被理由取代', () async {
    final a = _CaptureAdapter();
    final dio = build(host: true, adapter: a);
    await runWithHostReason('主持人理由', () async {
      await dio.post('/a', data: {'reason': '提議者的話'});
      await dio.post('/b', data: {'reason': ''});
    });
    expect(a.requests[0].data, {'reason': '提議者的話'});
    expect(a.requests[1].data, {'reason': '主持人理由'});
  });

  test('DELETE 走 query reason', () async {
    final a = _CaptureAdapter();
    final dio = build(host: true, adapter: a);
    await runWithHostReason('過期',
        () => dio.delete('/boards/b1', queryParameters: {'k': 1}));
    expect(a.requests.single.queryParameters, {'k': 1, 'reason': '過期'});
    expect(a.requests.single.data, isNull);
  });

  test('非主持人模式：不送 reason（即使 Zone 帶著）', () async {
    final a = _CaptureAdapter();
    final dio = build(host: false, adapter: a);
    await runWithHostReason('不該出現', () async {
      await dio.post('/x', data: {'a': 1});
      await dio.delete('/y');
    });
    expect(a.requests[0].data, {'a': 1});
    expect(a.requests[1].queryParameters, isEmpty);
    expect(a.requests[0].headers.containsKey('X-Host-View'), isFalse);
  });

  test('GET 不帶；空白理由等於沒有；Zone 結束後不外漏', () async {
    final a = _CaptureAdapter();
    final dio = build(host: true, adapter: a);
    await runWithHostReason('x', () => dio.get('/g'));
    await runWithHostReason('   ', () => dio.post('/p', data: {'a': 1}));
    await dio.post('/after', data: {'a': 2});
    expect(a.requests[0].queryParameters, isEmpty);
    expect(a.requests[1].data, {'a': 1});
    expect(a.requests[2].data, {'a': 2});
  });
}
