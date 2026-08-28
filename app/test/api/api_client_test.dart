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

    test('401 與 403 不可合併：型別必須不同', () {
      expect(translateError(_dioError(401)).runtimeType,
          isNot(translateError(_dioError(403)).runtimeType));
    });

    test('404 → NotFoundException', () {
      expect(translateError(_dioError(404)), isA<NotFoundException>());
    });

    test('409 → RoomArchivedException', () {
      final e = translateError(_dioError(409));
      expect(e, isA<RoomArchivedException>());
      expect(e.message, contains('封存'));
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
