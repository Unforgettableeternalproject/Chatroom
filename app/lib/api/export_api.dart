import 'dart:convert';

import 'package:dio/dio.dart';

import '../models/message.dart';
import 'api_client.dart';

/// 房間匯出。Hub 出原始 jsonl，排版留在 client（見 `export/conversation_format`）。
class ExportApi {
  ExportApi(this._dio);

  final Dio _dio;

  /// 抓整個房間的原始 jsonl。
  ///
  /// [participantId] 是必要的：匯出是**外流**——它把整個房間打包成一個檔案
  /// 交出去——所以 Hub 要求成員身分，不是只驗 token。被踢的人拿不到。
  ///
  /// 刻意回傳解析後的 `Message`，不回字串：匯出與畫面共用同一個模型，
  /// 「匯出的內容跟看到的不一樣」這種漂移才不會有生存空間。
  Future<List<Message>> fetchAll(
    String roomId, {
    required String participantId,
  }) =>
      unwrap(() async {
        final res = await _dio.get<String>(
          '/api/rooms/$roomId/export',
          queryParameters: {'format': 'jsonl'},
          options: Options(
            headers: {'X-Participant-Id': participantId},
            // ndjson 不是 dio 認得的型別，讓它原樣把 body 交出來
            responseType: ResponseType.plain,
          ),
        );
        return parseJsonl(res.data ?? '');
      });
}

/// 把 ndjson 切成訊息。
///
/// 匯出的價值在**完整**，所以這裡對格式寬容：空行跳過（結尾那個換行是正常
/// 的），但**壞掉的行不吞**——一則解析不了就整份失敗。安靜地少幾則，比明確
/// 地失敗糟得多：使用者會拿著一份看起來正常的檔案去當備份。
List<Message> parseJsonl(String body) {
  final out = <Message>[];
  for (final line in const LineSplitter().convert(body)) {
    if (line.trim().isEmpty) continue;
    out.add(Message.fromJson(jsonDecode(line) as Map<String, dynamic>));
  }
  return out;
}
