import 'dart:convert';
import 'dart:typed_data';

import 'package:chatroom_app/api/board_api.dart';
import 'package:chatroom_app/models/board.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

/// N-4 指派協定（Hub `483b257`）。
///
/// 🔴 **同一支端點兩種結果**：管理員直接寫到卡上（`assigned: true`），
/// 其他人生出一筆待對方回應的請求。UI **不預先判斷自己算不算管理員**——
/// 那個判準在 server（Hub 主持人／板 owner／卡所在房的建立者），複製到
/// client 就是第二份會漂移的真相。按下去，看 server 說發生了什麼。
///
/// 而畫面必須說得出是哪一種：說錯的話提議者會以為事情已經定了。
class _Canned implements HttpClientAdapter {
  _Canned(this.body);

  final Map<String, dynamic> body;
  RequestOptions? seen;

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? stream,
      Future<void>? cancel) async {
    seen = options;
    return ResponseBody.fromString(jsonEncode(body), 200,
        headers: {Headers.contentTypeHeader: [Headers.jsonContentType]});
  }

  @override
  void close({bool force = false}) {}
}

(BoardApi, _Canned) _api(Map<String, dynamic> body) {
  final a = _Canned(body);
  return (
    BoardApi(Dio(BaseOptions(baseUrl: 'http://test'))..httpClientAdapter = a),
    a
  );
}

void main() {
  test('管理員：直接指派，沒有請求', () async {
    final (api, _) = _api({'ok': true, 'assigned': true, 'request': null});
    final out = await api.assignTask('t1',
        participantId: 'p1', targetParticipantId: 'p2');
    expect(out.assigned, isTrue);
    expect(out.request, isNull);
  });

  test('🔴 一般人：沒有指派，生出一筆待回應的請求', () async {
    final (api, _) = _api({
      'ok': true,
      'assigned': false,
      'request': {
        'id': 'r1',
        'task_id': 't1',
        'requester_name': '我',
        'target_participant_id': 'p2',
        'target_name': '對方',
        'status': 'pending',
      },
    });
    final out = await api.assignTask('t1',
        participantId: 'p1', targetParticipantId: 'p2');
    expect(out.assigned, isFalse);
    expect(out.request!.status, 'pending');
    expect(out.request!.targetName, '對方');
  });

  test('🔴 重按同一個人不是失敗——Hub 回原本那筆', () async {
    // 不標出來的話，第二次按下去畫面會長出第二筆商量，
    // 而實際上只有一筆
    final (api, _) = _api({
      'ok': true,
      'assigned': false,
      'already_pending': true,
      'request': {'id': 'r1', 'task_id': 't1', 'status': 'pending'},
    });
    final out = await api.assignTask('t1',
        participantId: 'p1', targetParticipantId: 'p2');
    expect(out.alreadyPending, isTrue);
    expect(out.request!.id, 'r1');
  });

  test('送的是 participant_id，不是 session_key', () async {
    // Hub 不外流成員的 session_key，UI 手上只有 participant——
    // 送錯欄位會拿到一個指不到任何人的請求
    final (api, rec) = _api({'ok': true, 'assigned': true});
    await api.assignTask('t1', participantId: 'p1', targetParticipantId: 'p2');
    final body = rec.seen!.data as Map;
    expect(body['target_participant_id'], 'p2');
    expect(body['target_session_key'], '');
  });

  test('回應請求送的是 accept 布林', () async {
    final (api, rec) = _api({'ok': true});
    await api.resolveTaskRequest('r1', participantId: 'p1', accept: false);
    expect((rec.seen!.data as Map)['accept'], isFalse);
    expect(rec.seen!.path, contains('/task-requests/r1/resolve'));
  });

  group('請求的三種狀態在畫面上是三件事', () {
    TaskRequest req(String status) =>
        TaskRequest.fromJson({'id': 'r', 'task_id': 't', 'status': status});

    test('🔴 「他看過了說不要」與「他還沒看到」要分得出來', () {
      // 拒絕留紀錄不刪除（Hub 刻意）：提議者的下一步完全不同——
      // 前者要換人，後者要再等
      expect(req('declined').isDeclined, isTrue);
      expect(req('declined').isPending, isFalse);
      expect(req('pending').isPending, isTrue);
    });

    test('接受了也留著', () {
      expect(req('accepted').isAccepted, isTrue);
    });

    test('沒說狀態時當 pending——不可以當成已拒絕', () {
      expect(
          TaskRequest.fromJson({'id': 'r', 'task_id': 't'}).isPending, isTrue);
    });
  });

  test('🔴 task_requests 跟著板一起回，不必另外打一支端點', () {
    final snap = const BoardSnapshot().merge(BoardDelta.fromJson({
      'board_seq': 1,
      'full': true,
      'board_id': 'b1',
      'task_requests': [
        {'id': 'r1', 'task_id': 't1', 'status': 'pending'},
      ],
    }));
    expect(snap.taskRequests.single.id, 'r1');
  });

  test('增量沒送這個欄位時保留手上那份——已送出的請求不可以消失', () {
    final base = const BoardSnapshot().merge(BoardDelta.fromJson({
      'board_seq': 1,
      'full': true,
      'board_id': 'b1',
      'task_requests': [
        {'id': 'r1', 'task_id': 't1', 'status': 'pending'},
      ],
    }));
    final after = base.merge(BoardDelta.fromJson({'board_seq': 2}));
    expect(after.taskRequests, hasLength(1));
  });
}
