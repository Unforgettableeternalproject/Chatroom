import 'dart:convert';
import 'dart:typed_data';

import 'package:chatroom_app/api/board_api.dart';
import 'package:chatroom_app/models/board.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

/// 任務依賴／影響的請求與回應。
///
/// 🔴 `depends_on`／`affects` 是整份覆寫：**不送＝不動，空清單＝清空**。
/// 把「沒改」送成 `[]` 會讓只改標題的人把依賴整個清掉，而且沒有任何地方報錯。
class _Stub implements HttpClientAdapter {
  _Stub(this.body);

  final Map<String, dynamic> body;
  final List<RequestOptions> seen = [];

  @override
  Future<ResponseBody> fetch(
      RequestOptions options, Stream<Uint8List>? _, Future<void>? _) async {
    seen.add(options);
    return ResponseBody.fromString(jsonEncode(body), 200, headers: {
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
  test('改卡：只改標題時不送 depends_on / affects', () async {
    final stub = _Stub({'ok': true});
    await BoardApi(_dioWith(stub)).updateTask('t1', title: '新');
    final data = _dataOf(stub.seen.single);
    expect(data.containsKey('depends_on'), isFalse);
    expect(data.containsKey('affects'), isFalse);
  });

  test('改卡：帶 depends_on / affects 就整份送；空清單照送（清空）', () async {
    final stub = _Stub({'ok': true});
    await BoardApi(_dioWith(stub))
        .updateTask('t1', dependsOn: ['a', 'b'], affects: []);
    final req = stub.seen.single;
    expect(req.method, 'PATCH');
    expect(req.path, '/api/board/tasks/t1');
    expect(_dataOf(req)['depends_on'], ['a', 'b']);
    expect(_dataOf(req)['affects'], <String>[]);
  });

  test('改卡：回傳 dependency_changes', () async {
    final stub = _Stub({
      'dependency_changes': [
        {
          'id': 'x',
          'title': 'X',
          'from': 'in_progress',
          'to': 'blocked',
          'reason': 'dependency_unmet'
        }
      ]
    });
    final changes =
        await BoardApi(_dioWith(stub)).updateTask('t1', dependsOn: ['a']);
    expect(changes.single.id, 'x');
    expect(changes.single.isAutoBlocked, isTrue);
  });

  test('舊 Hub 沒有 dependency_changes ⇒ 空清單', () async {
    final stub = _Stub({'ok': true});
    final changes =
        await BoardApi(_dioWith(stub)).updateTask('t1', dependsOn: ['a']);
    expect(changes, isEmpty);
  });

  test('建立卡：帶依賴就送；沒帶就整個欄位不送，並回報連動', () async {
    final stub = _Stub({
      'id': 'new1',
      'dependency_changes': [
        {'id': 'y', 'reason': 'dependency_unmet'}
      ]
    });
    List<DependencyChange>? got;
    final id = await BoardApi(_dioWith(stub)).addTask('c1',
        title: '新卡',
        dependsOn: ['a'],
        affects: ['y'],
        onDependencyChanges: (c) => got = c);
    expect(id, 'new1');
    expect(_dataOf(stub.seen.single)['depends_on'], ['a']);
    expect(_dataOf(stub.seen.single)['affects'], ['y']);
    expect(got!.single.id, 'y');

    final stub2 = _Stub({'id': 'new2'});
    await BoardApi(_dioWith(stub2)).addTask('c1', title: '另一張');
    expect(_dataOf(stub2.seen.single).containsKey('depends_on'), isFalse);
    expect(_dataOf(stub2.seen.single).containsKey('affects'), isFalse);
  });

  test('狀態變更：回傳 dependency_changes（自動恢復）', () async {
    final stub = _Stub({
      'dependency_changes': [
        {'id': 'z', 'reason': 'dependency_met'}
      ]
    });
    final changes = await BoardApi(_dioWith(stub))
        .setTaskStatus('t1', status: 'done');
    expect(changes.single.isAutoResumed, isTrue);
  });
}
