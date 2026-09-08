import 'dart:convert';
import 'dart:typed_data';

import 'package:chatroom_app/api/board_api.dart';
import 'package:chatroom_app/core/config/app_settings.dart';
import 'package:chatroom_app/state/app_providers.dart';
import 'package:chatroom_app/state/board_providers.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// 搬卡：**去向要跟著搬走一起送出**（09/08 卡 240838ab）。
///
/// 這裡釘住兩件事：送出去的欄位長什麼樣，以及 [BoardActions.moveTask] 的
/// 兩步順序。後者是這張卡真正的重點——順序反了會留下一張「搬走了、去向
/// 空白」的卡，而那正是它要消滅的狀態。
class _Stub implements HttpClientAdapter {
  final List<RequestOptions> seen = [];

  @override
  Future<ResponseBody> fetch(
      RequestOptions options, Stream<Uint8List>? _, Future<void>? __) async {
    seen.add(options);
    final body = options.path.endsWith('/tasks')
        ? {'ok': true, 'id': 'new1'}
        : {'ok': true};
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
  group('BoardApi.setTaskStatus 的 moved_to', () {
    test('搬走時把去向一起送出去', () async {
      final stub = _Stub();
      await BoardApi(_dioWith(stub))
          .setTaskStatus('t1', status: 'moved', movedTo: 't99');
      final data = _dataOf(stub.seen.single);
      expect(data['status'], 'moved');
      expect(data['moved_to'], 't99');
    });

    test('去向空白時整個欄位不送——空字串與不送在 Hub 是同一件事', () async {
      final stub = _Stub();
      await BoardApi(_dioWith(stub)).setTaskStatus('t1', status: 'moved');
      expect(_dataOf(stub.seen.single).containsKey('moved_to'), isFalse);
    });

    test('不是搬走就不帶去向——別的狀態帶著它只會讓 Hub 存下一個沒意義的值',
        () async {
      final stub = _Stub();
      await BoardApi(_dioWith(stub))
          .setTaskStatus('t1', status: 'done', movedTo: 't99');
      expect(_dataOf(stub.seen.single).containsKey('moved_to'), isFalse);
    });
  });

  group('BoardActions.moveTask', () {
    test('先建新卡、再把舊卡指向它——順序反了會留下沒有去向的孤卡', () async {
      final stub = _Stub();
      final container = ProviderContainer(overrides: [
        dioProvider.overrideWithValue(_dioWith(stub)),
        // 板軸的身分走 session key，它從設定來——測試裡沒有 main() 幫忙
        // 塞初始設定，這裡自己給一份
        initialConfigProvider.overrideWithValue(const AppConfig(
          serverUrl: 'http://test',
          token: 't',
          themeMode: ThemeModePref.dark,
          preferredName: '',
          deviceKey: 'dev-1',
        )),
      ]);
      addTearDown(container.dispose);

      final newId = await container
          .read(boardActionsByIdProvider('b1'))
          .moveTask('t1',
              targetChecklistId: 'c9', title: '搬過去的事', description: '描述');

      expect(newId, 'new1');
      expect(stub.seen.length, 2);
      // 第一步是建卡，第二步才是推狀態。**這個順序是這張卡的不變式**
      expect(stub.seen[0].path, '/api/board/checklists/c9/tasks');
      expect(_dataOf(stub.seen[0])['title'], '搬過去的事');
      expect(stub.seen[1].path, '/api/board/tasks/t1/status');
      expect(_dataOf(stub.seen[1])['moved_to'], 'new1');
    });
  });
}
