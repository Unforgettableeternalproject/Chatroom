import 'dart:convert';
import 'dart:typed_data';

import 'package:chatroom_app/api/notifications_api.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

class _Adapter implements HttpClientAdapter {
  _Adapter(this.body);

  final Map<String, dynamic> body;
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    requests.add(options);
    return ResponseBody.fromString(jsonEncode(body), 200, headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    });
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  final listBody = {
    'unread_count': 2,
    'notifications': [
      {
        'id': 12,
        'kind': 'host_room_archived',
        'room_id': 'r1',
        'room_name': '房一',
        'board_id': 'b1',
        'board_name': '板一',
        'item_kind': 'task',
        'item_id': 't1',
        'item_title': '卡',
        'actor_name': 'Bernie',
        'actor_kind': 'host',
        'reason': '清理',
        'summary': '房間被封存',
        'count': 3,
        'created_at': '2026-11-11T00:00:00Z',
        'updated_at': '2026-11-11T01:00:00Z',
        'read_at': null,
        'for_host': true,
      },
      {'id': 11, 'summary': '舊的', 'read_at': '2026-11-10T00:00:00Z'},
    ],
  };

  test('list：帶 query 與 session key，解析全部欄位', () async {
    final adapter = _Adapter(listBody);
    final dio = Dio(BaseOptions(baseUrl: 'http://hub.test'))
      ..httpClientAdapter = adapter;
    final page = await NotificationsApi(dio)
        .list(sessionKey: 'sk', unreadOnly: true, limit: 10, beforeId: 9);

    final req = adapter.requests.single;
    expect(req.path, '/api/notifications');
    expect(req.queryParameters,
        {'unread_only': true, 'limit': 10, 'before_id': 9});
    expect(req.headers['X-Session-Key'], 'sk');

    expect(page.unreadCount, 2);
    final n = page.items.first;
    expect(n.id, 12);
    expect(n.roomName, '房一');
    expect(n.boardName, '板一');
    expect(n.actorKind, 'host');
    expect(n.byHost, isTrue);
    expect(n.reason, '清理');
    expect(n.count, 3);
    expect(n.displayTime, '2026-11-11T01:00:00Z');
    expect(n.forHost, isTrue);
    expect(n.unread, isTrue);
    expect(n.targetRoute, '/boards/b1?task=t1');
    // 缺欄位的通知照樣解析，count 退回 1
    final old = page.items.last;
    expect(old.count, 1);
    expect(old.displayTime, '2026-11-10T00:00:00Z'.isEmpty ? null : old.createdAt);
    expect(old.unread, isFalse);
    expect(old.targetRoute, isNull);
  });

  test('list：沒有 before_id 就不送', () async {
    final adapter = _Adapter(listBody);
    final dio = Dio(BaseOptions(baseUrl: 'http://hub.test'))
      ..httpClientAdapter = adapter;
    await NotificationsApi(dio).list(sessionKey: 'sk');
    expect(adapter.requests.single.queryParameters.containsKey('before_id'),
        isFalse);
  });

  test('markRead：ids 與 all 的 body；兩者皆空不送請求', () async {
    final adapter = _Adapter({'ok': true});
    final dio = Dio(BaseOptions(baseUrl: 'http://hub.test'))
      ..httpClientAdapter = adapter;
    final api = NotificationsApi(dio);

    await api.markRead(sessionKey: 'sk', ids: [1, 2]);
    await api.markRead(sessionKey: 'sk', all: true);
    await api.markRead(sessionKey: 'sk');

    expect(adapter.requests.length, 2);
    expect(adapter.requests[0].path, '/api/notifications/read');
    expect(adapter.requests[0].method, 'POST');
    expect(adapter.requests[0].data, {'ids': [1, 2]});
    expect(adapter.requests[1].data, {'all': true});
  });
}
