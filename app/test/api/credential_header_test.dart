import 'dart:convert';
import 'dart:typed_data';

import 'package:chatroom_app/api/assignments_api.dart';
import 'package:chatroom_app/api/rooms_api.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

/// 87ec8297：憑證位置統一到 header。
///
/// App 原本有**四處**把 `session_key` 送在 body／query（其餘早就走
/// `X-Session-Key`）。Hub `f2f9c1e` 起四支都收 header 且 **header 優先**，
/// 所以這裡直接切、不雙送——雙送會讓「我改成 header 了」在悄悄用舊位置時
/// 看起來也像生效。
///
/// ⚠️ **這組測試釘的是「舊位置不再被使用」，不只是「header 有帶」。**
/// 只驗後者的話，一個仍然雙送的實作也會通過，而相容期結束那天它就壞了，
/// 到那時沒有人記得該回頭看這裡。
///
/// ⚠️ 同樣要釘的是**沒有被搬走的那些**：`kind` / `label` / `host` 是向
/// session 名錄自報的資訊，不是憑證。照字串搜尋一起搬的話，名錄會少掉
/// 分辨機器的依據，而那不會報錯。
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

void main() {
  test('GET /api/rooms：憑證在 header，自報資訊留 query', () async {
    final rec = _Rec({'rooms': []});
    await RoomsApi(_dio(rec)).list(sessionKey: 'k1', label: '我');

    final req = rec.seen.single;
    expect(req.headers['X-Session-Key'], 'k1');
    expect(req.queryParameters.containsKey('session_key'), isFalse);
    expect(req.queryParameters['kind'], 'human', reason: '這個不是憑證');
    expect(req.queryParameters['label'], '我', reason: '這個也不是');
  });

  test('沒有 session key 時不要送一個空的 header', () async {
    // 空字串在 Hub 那端不是「沒有」，是一個值。列公開房本來就可以匿名
    final rec = _Rec({'rooms': []});
    await RoomsApi(_dio(rec)).list();
    expect(rec.seen.single.headers.containsKey('X-Session-Key'), isFalse);
  });

  test('POST /api/rooms：憑證離開 body，其餘欄位不動', () async {
    final rec = _Rec({
      'id': 'r1',
      'name': '房',
      'topic': '',
      'status': 'active',
      'created_at': '2026-09-01T00:00:00+00:00',
    });
    await RoomsApi(_dio(rec)).create(name: '房', sessionKey: 'k2');

    final req = rec.seen.single;
    expect(req.headers['X-Session-Key'], 'k2');
    final body = req.data as Map<String, dynamic>;
    expect(body.containsKey('session_key'), isFalse);
    expect(body['name'], '房');
    expect(body['visibility'], 'public');
  });

  test('POST /join：憑證離開 body，role 與 kind 留著', () async {
    // ⚠️ role 漏掉的症狀是「人類被 sweeper 當成閒置 agent 掃出房間」，
    // 與憑證位置無關但同一個 body——搬東西時最容易把它一起碰壞
    final rec = _Rec({
      'participant_id': 'p1',
      'display_name': 'Bernie',
      'rejoined': false,
    });
    await RoomsApi(_dio(rec))
        .join('r1', kind: 'human', sessionKey: 'k3', role: 'human');

    final req = rec.seen.single;
    expect(req.headers['X-Session-Key'], 'k3');
    final body = req.data as Map<String, dynamic>;
    expect(body.containsKey('session_key'), isFalse);
    expect(body['role'], 'human');
    expect(body['kind'], 'human');
  });

  test('GET /api/assignments：憑證在 header，自報資訊留 query', () async {
    final rec = _Rec({'assignments': []});
    await AssignmentsApi(_dio(rec))
        .listForSession('k4', kind: 'codex', label: 'Codex-1', host: 'PC');

    final req = rec.seen.single;
    expect(req.headers['X-Session-Key'], 'k4');
    expect(req.queryParameters.containsKey('session_key'), isFalse);
    expect(req.queryParameters['host'], 'PC');
  });
}
