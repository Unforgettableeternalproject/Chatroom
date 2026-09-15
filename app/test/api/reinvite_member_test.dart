import 'dart:convert';
import 'dart:typed_data';

import 'package:chatroom_app/api/assignments_api.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

/// 可以指定回應內容的 adapter。共用的 Recorder 固定回 `{"ok":true}`，
/// 而這裡要驗的正是「回應裡的某一欄有沒有被接住」。
class _Stub implements HttpClientAdapter {
  _Stub([this.reply = const {'id': 'm1', 'seq': 1}]);

  Map<String, dynamic> reply;
  final List<RequestOptions> seen = [];

  @override
  Future<ResponseBody> fetch(
      RequestOptions options, Stream<Uint8List>? _, Future<void>? _) async {
    seen.add(options);
    return ResponseBody.fromString(jsonEncode(reply), 200, headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    });
  }

  @override
  void close({bool force = false}) {}
}

/// 「請他重新加入」走的是既有的指派——被閒置移出之後 watcher 並沒有跟著
/// 消失，那把 session 還在 Hub 名錄裡。
///
/// 成敗全落在一件事上：**目標要用 participant_id**。成員的 session_key
/// 刻意不外流（它同時是指派目標），App 手上根本沒有——送空字串的話 Hub
/// 會建立一筆指派給「沒有人」，而那與成功長得一模一樣。
void main() {
  late _Stub stub;
  late AssignmentsApi api;

  setUp(() {
    stub = _Stub({'id': 'a1'});
    api = AssignmentsApi(
        Dio(BaseOptions(baseUrl: 'http://test'))..httpClientAdapter = stub);
  });

  test('用 participant_id 指定目標', () async {
    await api.create('r1',
        targetParticipantId: 'p-gone',
        note: '請重新加入這個聊天室。',
        assignedName: '開發Novia-1');
    final body = stub.seen.single.data as Map;
    expect(body['target_participant_id'], 'p-gone');
    expect(body.containsKey('target_session_key'), isFalse,
        reason: 'App 手上沒有 session_key，不可以送一個空字串上去');
    expect(body['assigned_name'], '開發Novia-1',
        reason: '用原本的名字回來——歷史訊息都掛在那個名字上');
  });

  test('正典那條沒被改壞', () async {
    await api.create('r1', targetSessionKey: 'codex-main');
    final body = stub.seen.single.data as Map;
    expect(body['target_session_key'], 'codex-main');
    expect(body.containsKey('target_participant_id'), isFalse);
  });
}
