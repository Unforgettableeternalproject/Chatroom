import 'dart:convert';
import 'dart:typed_data';

import 'package:chatroom_app/api/board_api.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

/// 週期與階段的改名／改敘述（09/08 卡 32f26b75）。
///
/// Hub 早就收（`_board_patch`），守門也已經收緊到 owner／supervisor／建立者
/// （`2f0a06a`）——缺的一直只有 App 這一側。
///
/// ⚠️ 這裡守的是 **null 與空字串不是同一件事**：`_board_patch` 只跳過 null，
/// 空字串是一個真的值，會把敘述清掉。只改標題卻把敘述一起送成空字串的話，
/// 使用者會發現敘述不見了，而且沒有任何地方報錯。
class _Stub implements HttpClientAdapter {
  final List<RequestOptions> seen = [];

  @override
  Future<ResponseBody> fetch(
      RequestOptions options, Stream<Uint8List>? _, Future<void>? _) async {
    seen.add(options);
    return ResponseBody.fromString(jsonEncode({'ok': true}), 200, headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    });
  }

  @override
  void close({bool force = false}) {}
}

Dio _dioWith(_Stub stub) =>
    Dio(BaseOptions(baseUrl: 'http://test'))..httpClientAdapter = stub;

Map<String, dynamic> _dataOf(RequestOptions o) =>
    (o.data as Map).cast<String, dynamic>();

void main() {
  test('改週期標題：打對端點，只送有動到的欄位', () async {
    final stub = _Stub();
    await BoardApi(_dioWith(stub)).updateObjective('o1', title: '新名字');

    final req = stub.seen.single;
    expect(req.method, 'PATCH');
    expect(req.path, '/api/board/objectives/o1');
    expect(_dataOf(req)['title'], '新名字');
    // 🔴 沒動敘述就整個欄位不送——送 null 或空字串都會讓它被清掉
    expect(_dataOf(req).containsKey('description'), isFalse);
  });

  test('只改敘述時標題不跟著送', () async {
    final stub = _Stub();
    await BoardApi(_dioWith(stub)).updateObjective('o1', description: '說明');

    expect(_dataOf(stub.seen.single).containsKey('title'), isFalse);
    expect(_dataOf(stub.seen.single)['description'], '說明');
  });

  test('空字串是「清空」，是使用者真的做了那件事——要送出去', () async {
    final stub = _Stub();
    await BoardApi(_dioWith(stub)).updateObjective('o1', description: '');

    expect(_dataOf(stub.seen.single)['description'], '');
  });

  test('改階段走 checklists 端點，規則相同', () async {
    final stub = _Stub();
    await BoardApi(_dioWith(stub))
        .updateChecklist('c1', title: '新階段', description: '');

    final req = stub.seen.single;
    expect(req.path, '/api/board/checklists/c1');
    expect(_dataOf(req)['title'], '新階段');
    expect(_dataOf(req)['description'], '');
  });
}
