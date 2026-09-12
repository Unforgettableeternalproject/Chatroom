import 'dart:convert';
import 'dart:typed_data';

import 'package:chatroom_app/api/api_client.dart';
import 'package:chatroom_app/api/tokens_api.dart';
import 'package:chatroom_app/core/errors/api_exception.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

/// App 發出的邀請碼進不了任何房間（09/12 艾斯維爾在別人的 Hub 上實測）。
///
/// Hub 的 `TokenCreate.audience` 預設是 **agent**（保守是對的，那一端不改），
/// 而 App 這個入口發的邀請**永遠是給人的**——`CHATROOM-INVITE-` 這個格式
/// 只有 App 認得，mcp-kit 根本不吃它，所以「在 App 上發一張 agent 邀請碼」
/// 這條路從來就走不完。不明講 audience 的後果是：分離期的 Hub 把每一張
/// App 發出的邀請都擋在 `role=human` 那一刻，而發的人以為自己給了一把鑰匙。
void main() {
  test('發邀請時明講這張是給人的', () async {
    final rec = _Rec({'token': 't', 'label': '給艾斯維爾'});
    await TokensApi(_dio(rec)).create(label: '給艾斯維爾');

    expect(rec.seen.single.data, {'label': '給艾斯維爾', 'audience': 'human'});
  });

  test('human_token_required 不是身分失效，不可觸發 re-join', () {
    // 走 ParticipantInvalidException 的話 App 會自動重新加入——而重新加入
    // 一百次也不會讓一張 agent 憑證變成人類憑證。那是一個永遠不會成功、
    // 看起來卻像卡住的迴圈
    final e = translateError(DioException(
      requestOptions: RequestOptions(path: '/api/rooms/r1/join'),
      response: Response(
        requestOptions: RequestOptions(path: '/api/rooms/r1/join'),
        statusCode: 403,
        data: {
          'detail': {
            'code': 'human_token_required',
            'message': '以人類身分加入只認人類憑證',
          }
        },
      ),
    ));

    expect(e, isA<HumanCredentialRequiredException>());
    expect(e, isNot(isA<ParticipantInvalidException>()));
  });
}

class _Rec implements HttpClientAdapter {
  _Rec([this.body = const {'ok': true}]);

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

Dio _dio(_Rec rec) =>
    Dio(BaseOptions(baseUrl: 'http://test'))..httpClientAdapter = rec;
