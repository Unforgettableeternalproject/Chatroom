import 'dart:convert';
import 'dart:typed_data';

import 'package:chatroom_app/api/messages_api.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

/// 可以指定回應內容的 adapter。共用的 Recorder 固定回 `{"ok":true}`，
/// 而這裡要驗的正是「回應裡的某一欄有沒有被接住」。
class _Stub implements HttpClientAdapter {
  Map<String, dynamic> reply = const {'id': 'm1', 'seq': 1};
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

/// 「戳一下」走的是一般訊息的 mention 路徑，所以它的成敗全落在兩件事上：
/// **mentions 有沒有帶成參數**、**unresolved 有沒有被看見**。
///
/// 兩個都是無聲失效：內文寫 `@名字` 不會被解析成 mention 也不會報錯；
/// 名字對不上時 Hub 照樣回 200，只是把它放進 unresolved_mentions。
/// 兩種情況在畫面上都跟成功長得一模一樣。
void main() {
  late _Stub stub;
  late MessagesApi api;

  setUp(() {
    stub = _Stub();
    api = MessagesApi(
        Dio(BaseOptions(baseUrl: 'http://test'))..httpClientAdapter = stub);
  });

  test('mention 走參數，不是靠內文的 @', () async {
    await api.post('r1',
        participantId: 'p1',
        content: '@Codex-Sol 在嗎？有事找你，回來看一下。',
        mentions: const ['Codex-Sol']);
    final body = stub.seen.single.data as Map;
    expect(body['mentions'], ['Codex-Sol']);
  });

  test('unresolved_mentions 要接得到——沒接的話「沒戳到」看不出來', () async {
    stub.reply = {
      'id': 'm1',
      'seq': 9,
      'unresolved_mentions': ['Codex-Sol'],
    };
    final res = await api.post('r1',
        participantId: 'p1', content: 'hi', mentions: const ['Codex-Sol']);
    expect(res.unresolvedMentions, ['Codex-Sol']);
  });

  test('舊 Hub 沒回這一欄時是空清單，不是炸掉', () async {
    final res = await api.post('r1', participantId: 'p1', content: 'hi');
    expect(res.unresolvedMentions, isEmpty);
  });
}
