import 'package:chatroom_app/api/board_api.dart';
import 'package:chatroom_app/models/board.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import '../api/identity_headers_test.dart' show Recorder;

/// 板分公開與私人（艾斯維爾 2026-09-03）。這裡釘住 UI 這側的兩端：
/// 建立時送出去的值，與清單讀回來的值。
void main() {
  group('建板時送 visibility', () {
    late Recorder rec;
    late BoardsApi api;

    setUp(() {
      rec = Recorder();
      api = BoardsApi(
          Dio(BaseOptions(baseUrl: 'http://test'))..httpClientAdapter = rec);
    });

    test('預設公開——私人是一條窄路，不該讓人在沒選的情況下走上去', () async {
      await api.create(name: '新板', sessionKey: 'k1');
      final body = rec.seen.single.data as Map;
      expect(body['visibility'], 'public');
    });

    test('選了私人就送私人', () async {
      await api.create(name: '新板', sessionKey: 'k1', visibility: 'private');
      expect((rec.seen.single.data as Map)['visibility'], 'private');
    });

    test('從 Library 開的板不掛任何房——origin_room_id 不送', () async {
      await api.create(name: '新板', sessionKey: 'k1');
      expect((rec.seen.single.data as Map).containsKey('origin_room_id'),
          isFalse);
    });
  });

  group('清單讀得出 visibility', () {
    BoardSummary parse(Map<String, dynamic> json) =>
        BoardSummary.fromJson({'id': 'b1', ...json});

    test('私人板標得出來', () {
      expect(parse({'visibility': 'private'}).isPrivate, isTrue);
    });

    test('公開板不標', () {
      expect(parse({'visibility': 'public'}).isPrivate, isFalse);
    });

    test('🔴 舊 Hub 沒回這欄時當公開——當私人的話，畫面會憑空長出一個'
        '使用者從未設定過的限制', () {
      expect(parse({}).visibility, 'public');
      expect(parse({}).isPrivate, isFalse);
    });
  });
}
