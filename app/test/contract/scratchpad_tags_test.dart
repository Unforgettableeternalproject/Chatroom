import 'dart:convert';
import 'dart:typed_data';

import 'package:chatroom_app/api/board_api.dart';
import 'package:chatroom_app/api/scratchpad_api.dart';
import 'package:chatroom_app/core/errors/api_exception.dart';
import 'package:chatroom_app/models/board.dart';
import 'package:chatroom_app/models/scratchpad.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

/// 想法板段落標籤的 UI 半邊（server 半邊 `28137c6`，契約 #411）。
///
/// 定案：**單選**、預設集合 `bug/feature/design/question`、每塊板可自訂額外
/// 標籤、刪除還有段落在用的自訂標籤回 409 帶 `block_ids`／`pad_ids`。
///
/// 🔴 **選單內容一律來自 `allowed_tags`（預設 ∪ 這塊板自訂的），UI 不得自己
/// 寫死一份預設集合。** 寫死的那份是第二個判準：板自訂的標籤它永遠不會知道，
/// 而兩份判準漂移的時候沒有任何一邊會報錯。
///
/// schema 寬、行為窄：欄位是陣列（之後要改多選不必動資料），UI 只給選一個。
class _Canned implements HttpClientAdapter {
  _Canned(this.body, {this.status = 200});

  final Map<String, dynamic> body;
  final int status;
  final List<RequestOptions> seen = [];

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? stream,
      Future<void>? cancel) async {
    seen.add(options);
    return ResponseBody.fromString(jsonEncode(body), status,
        headers: {Headers.contentTypeHeader: [Headers.jsonContentType]});
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  group('段落帶著自己的標籤回來', () {
    test('讀得到 tags', () {
      final b = ScratchpadBlock.fromJson(const {
        'id': 'blk1',
        'content': '主持人模式按了沒反應',
        'tags': ['bug'],
      });
      expect(b.tags, ['bug']);
      expect(b.tag, 'bug', reason: '行為是單選，畫面要的是那一個');
    });

    test('沒有標籤的段落不是壞掉——舊資料本來就沒有', () {
      final b = ScratchpadBlock.fromJson(const {'id': 'blk1'});
      expect(b.tags, isEmpty);
      expect(b.tag, isNull, reason: 'null 才分得出「沒標」與「標了空字串」');
    });
  });

  group('選單內容來自板，不是寫死在 UI', () {
    test('BoardDelta 讀得到 allowed_tags', () {
      final d = BoardDelta.fromJson(const {
        'board_seq': 1,
        'allowed_tags': ['bug', 'feature', 'design', 'question', '權限'],
      });
      expect(d.allowedTags, contains('權限'), reason: '板自訂的那些只有 Hub 知道');
      expect(d.allowedTags, hasLength(5));
    });

    test('🔴 舊 Hub 不回這一欄時是空的，UI 不可以自己補一份預設集合', () {
      final d = BoardDelta.fromJson(const {'board_seq': 1});
      expect(d.allowedTags, isEmpty,
          reason: '補了就是第二個判準——板自訂的標籤它永遠不會知道，'
              '而兩份漂移時沒有一邊會報錯');
    });

    test('🔴 增量沒帶這一欄時保留手上那份，不是清空', () {
      // 跟著清空的話，選單會在第二次拉取之後整個消失——而畫面上那看起來
      // 像「這塊板沒有標籤功能」，不像掉了一份資料
      final full = const BoardSnapshot().merge(BoardDelta.fromJson(const {
        'board_seq': 1,
        'allowed_tags': ['bug', 'feature', '權限'],
      }));
      expect(full.allowedTags, hasLength(3));

      final next = full.merge(BoardDelta.fromJson(const {'board_seq': 2}));
      expect(next.allowedTags, hasLength(3), reason: '增量不重送中繼資料');
    });
  });

  group('寫入時把標籤一起送出', () {
    test('新增段落帶 tags', () async {
      final canned = _Canned({'ok': true, 'id': 'blk9'});
      final api = ScratchpadApi(
          Dio(BaseOptions(baseUrl: 'http://test'))..httpClientAdapter = canned);
      await api.addBlock('b1', 'p1',
          sessionKey: 'k', content: '一則觀察', tags: const ['bug']);
      expect(canned.seen.single.data['tags'], ['bug']);
    });

    test('改段落也帶 tags——改內容與改標籤走同一支，rev 照舊必填', () async {
      final canned = _Canned({'ok': true, 'rev': 3});
      final api = ScratchpadApi(
          Dio(BaseOptions(baseUrl: 'http://test'))..httpClientAdapter = canned);
      final rev = await api.writeBlock('b1', 'p1', 'blk1',
          sessionKey: 'k', content: '改過', rev: 2, tags: const ['feature']);
      expect(rev, 3);
      expect(canned.seen.single.data['tags'], ['feature']);
      expect(canned.seen.single.data['rev'], 2);
    });

    test('不指定 tags 時送空陣列——那是「沒有標籤」，不是「別動它」', () async {
      final canned = _Canned({'ok': true, 'id': 'blk9'});
      final api = ScratchpadApi(
          Dio(BaseOptions(baseUrl: 'http://test'))..httpClientAdapter = canned);
      await api.addBlock('b1', 'p1', sessionKey: 'k', content: '一則觀察');
      expect(canned.seen.single.data['tags'], isEmpty);
    });
  });

  group('板自訂標籤', () {
    test('註冊新標籤，回傳新的選單內容', () async {
      final canned = _Canned({
        'ok': true,
        'tags': ['權限'],
        'allowed': ['bug', 'feature', 'design', 'question', '權限'],
        'added': ['權限'],
      });
      final api = BoardsApi(
          Dio(BaseOptions(baseUrl: 'http://test'))..httpClientAdapter = canned);
      final r = await api.addTags('b1', sessionKey: 'k', tags: const ['權限']);
      expect(r.allowed, contains('權限'));
      expect(canned.seen.single.data['tags'], ['權限']);
    });

    test('🔴 刪除還有段落在用的標籤 → 409，而且指得出是哪幾則', () async {
      // 擋下來而已是把問題換個地方放；擋下來**並指得出路**才是這個做法
      final canned = _Canned({
        'detail': {
          'code': 'tag_in_use',
          'message': '還有段落在用這個標籤',
          'block_ids': ['blk1', 'blk2'],
          'pad_ids': ['p1'],
        }
      }, status: 409);
      final api = BoardsApi(
          Dio(BaseOptions(baseUrl: 'http://test'))..httpClientAdapter = canned);
      // ⚠️ 刻意**不新開一個例外型別**：`ConflictException` 已經把拒絕裡的
      // 其餘欄位原樣帶過來（`api_client.dart` 的既有決定——每加一個欄位就
      // 改一次型別的話，那些資訊多半就不會有人接）
      await expectLater(
        api.removeTag('b1', '權限', sessionKey: 'k'),
        throwsA(isA<ConflictException>()
            .having((e) => e.code, 'code', 'tag_in_use')
            .having((e) => e.detail['block_ids'], 'block_ids', ['blk1', 'blk2'])
            .having((e) => e.detail['pad_ids'], 'pad_ids', ['p1'])),
      );
    });
  });
}
