import 'package:chatroom_app/api/api_client.dart';
import 'package:chatroom_app/core/errors/api_exception.dart';
import 'package:chatroom_app/core/logging/redacting_logger.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

DioException _dioError(int status, {Map<String, dynamic>? detail}) {
  final options = RequestOptions(path: '/api/test');
  return DioException(
    requestOptions: options,
    response: Response(
      requestOptions: options,
      statusCode: status,
      data: detail == null ? null : {'detail': detail},
    ),
  );
}

void main() {
  group('translateError（P3-03 條件 2：401/403/404/409 轉具語意例外）', () {
    test('401 → AuthException（設定問題，導向設定頁）', () {
      final e = translateError(
          _dioError(401, detail: {'code': 'invalid_token', 'message': 'x'}));
      expect(e, isA<AuthException>());
      expect(e.code, 'invalid_token');
      expect(e.message, contains('token'));
    });

    test('403 → ParticipantInvalidException（身分過期，觸發 re-join）', () {
      final e = translateError(_dioError(403,
          detail: {'code': 'participant_not_active', 'message': 'x'}));
      expect(e, isA<ParticipantInvalidException>());
    });

    test('403 沿用 Hub 的原話——「沒有資格做這件事」不可講成「身分壞了」', () {
      final e = translateError(_dioError(403, detail: {
        'code': 'participant_not_active',
        'message': '你已經不在這個聊天室裡了，無法執行房內的管理動作',
      }));
      expect(e, isA<ParticipantInvalidException>());
      expect(e.message, contains('無法執行房內的管理動作'));
      // 按下封存卻被告知「正在重新加入」，那件事不會發生
      expect(e.message, isNot(contains('重新加入')));
    });

    test('403 沒帶 message 時才退回寫死的那句', () {
      final e = translateError(
          _dioError(403, detail: {'code': 'participant_not_active'}));
      expect(e.message, contains('重新加入'));
    });

    test('403 + root_token_required 不可當成身分失效——'
        '那會觸發自動 re-join，而重新加入不會讓人變成 Hub 主持人', () {
      final e = translateError(_dioError(403, detail: {
        'code': 'root_token_required',
        'message': '只有 Hub 主持人（.env 的主 token）能發放或撤銷邀請',
      }));
      expect(e, isA<RootTokenRequiredException>());
      expect(e, isNot(isA<ParticipantInvalidException>()));
    });

    test('401 與 403 不可合併：型別必須不同', () {
      expect(translateError(_dioError(401)).runtimeType,
          isNot(translateError(_dioError(403)).runtimeType));
    });

    test('413 → AttachmentTooLargeException，且沿用 Hub 講的實際上限', () {
      final e = translateError(_dioError(413, detail: {
        'code': 'attachment_too_large',
        'message': '檔案超過上限 25 MB',
      }));
      expect(e, isA<AttachmentTooLargeException>());
      // 上限是伺服器設定的，App 不知道；訊息必須來自 Hub 而不是自己編
      expect(e.message, contains('25 MB'));
    });

    test('413 不可掉進 ServerException——那是「伺服器壞了」，這是使用者可修正的',
        () {
      expect(translateError(_dioError(413)), isNot(isA<ServerException>()));
    });

    test('410 → AttachmentGoneException（metadata 在、實體不在）', () {
      final e = translateError(_dioError(410,
          detail: {'code': 'attachment_blob_missing', 'message': 'x'}));
      expect(e, isA<AttachmentGoneException>());
      expect(e.code, 'attachment_blob_missing');
    });

    test('404 → NotFoundException', () {
      expect(translateError(_dioError(404)), isA<NotFoundException>());
    });

    test('409 → RoomArchivedException', () {
      final e = translateError(_dioError(409));
      expect(e, isA<RoomArchivedException>());
      expect(e.message, contains('封存'));
    });

    // 409 不是只有一種——403 已經吸取過這個教訓（見 translateError 的註解），
    // 409 還沒。Board 的認領衝突與非法轉移都是 409，把它們一律講成
    // 「此聊天室已封存，無法發言」會讓人去找一個根本沒有封存的房間。
    test('409 conflict → 帶 Hub 的 code 與訊息，不再一律說封存', () {
      final e = translateError(_dioError(409, detail: {
        'code': 'task_already_claimed',
        'message': '這張卡已經被 Swift-Falcon 領走了',
      }));
      expect(e, isA<ConflictException>());
      expect(e.code, 'task_already_claimed');
      expect(e.message, contains('Swift-Falcon'));
      expect(e.message, isNot(contains('封存')));
    });

    test('409 room_archived 仍是 RoomArchivedException', () {
      final e = translateError(_dioError(409, detail: {
        'code': 'room_archived',
        'message': '此聊天室已封存',
      }));
      expect(e, isA<RoomArchivedException>());
    });

    test('409 invalid_transition 帶得出 allowed——App 可以直接拿它畫按鈕', () {
      final e = translateError(_dioError(409, detail: {
        'code': 'invalid_transition',
        'message': '不能從「完成」回到「進行中」',
        'allowed': ['cancelled'],
      }));
      expect(e, isA<ConflictException>());
      expect((e as ConflictException).allowed, ['cancelled']);
    });

    /// 🔴 Hub 用 `_err(**extra)` 把「往下走的資訊」放進拒絕裡，而那是一個
    /// **開放集合**（`allowed` / `reopen_to` / `open` / `item_id`⋯⋯）。
    /// 為每個新欄位改一次型別的話，那些資訊多半就不會有人接——bridge 那側
    /// 已經發生過一次（F1：`_detail_text` 只取 message，其餘全丟）。
    test('🔴 409 的其餘 detail 欄位原樣帶到 App——不要只留 message', () {
      final e = translateError(_dioError(409, detail: {
        'code': 'container_settled',
        'message': '這個階段已經完成了，不能再往裡面加東西',
        'kind': 'checklist',
        'item_id': 'c1',
        'item_status': 'done',
        'reopen_to': 'open',
      })) as ConflictException;

      // 擋的可能是**祖父層**，所以 item_id 不能由 App 自己猜
      expect(e.detail['kind'], 'checklist');
      expect(e.detail['item_id'], 'c1');
      expect(e.detail['reopen_to'], 'open');
    });

    test('沒有 detail 時是空 map，不是 null——呼叫端不必處理兩種空', () {
      final e = translateError(_dioError(409,
          detail: {'code': 'task_already_claimed', 'message': 'x'}));
      expect((e as ConflictException).detail['kind'], isNull);
      expect(e.detail.containsKey('reopen_to'), isFalse);
    });

    test('422 → ValidationException 且帶 server 的 message', () {
      final e = translateError(_dioError(422,
          detail: {'code': 'reply_target_not_found', 'message': '目標不存在'}));
      expect(e, isA<ValidationException>());
      expect(e.message, '目標不存在');
    });

    test('無 response（連不上）→ NetworkException', () {
      final e = translateError(
          DioException(requestOptions: RequestOptions(path: '/x')));
      expect(e, isA<NetworkException>());
    });

    test('500 → ServerException 帶狀態碼', () {
      final e = translateError(_dioError(500));
      expect(e, isA<ServerException>());
      expect(e.message, contains('500'));
    });
  });

  group('redact（P3-02 條件 4：token 不出現在 log）', () {
    test('Bearer token 被遮蔽', () {
      expect(redact('Authorization: Bearer super-secret-123'),
          isNot(contains('super-secret-123')));
    });

    test('WS query string 的 token 被遮蔽', () {
      final out = redact('ws://127.0.0.1:8787/ws?token=dev-secret-0827');
      expect(out, isNot(contains('dev-secret-0827')));
      expect(out, contains('token=«REDACTED»'));
    });

    test('一般文字不受影響', () {
      expect(redact('連線建立 room=abc'), '連線建立 room=abc');
    });
  });
}
