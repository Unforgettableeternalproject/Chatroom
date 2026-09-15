import 'dart:convert';
import 'dart:typed_data';

import 'package:chatroom_app/api/rooms_api.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

/// 🔴 2026-09-03：`you_are_admin` 在**回應頂層**，不在 `room` 物件裡。
///
/// 房間**列表**那支端點把它塞進每一個 room（那裡沒有頂層可放），**詳情**
/// 那支放在頂層。寫成 `detail.room.youAreAdmin` 不會報錯，只會**永遠是
/// false**——而症狀是「指派 Supervisor 的按鈕沒出現」，看起來像功能沒做。
///
/// 兩處都踩過：Supervisor 面板的指派、聊天室頁首的「掛接任務板」。
class _Canned implements HttpClientAdapter {
  _Canned(this.body);

  final Map<String, dynamic> body;

  @override
  Future<ResponseBody> fetch(
      RequestOptions options, Stream<Uint8List>? stream, Future<void>? cancel) async {
    return ResponseBody.fromString(jsonEncode(body), 200, headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    });
  }

  @override
  void close({bool force = false}) {}
}

RoomsApi _api(Map<String, dynamic> body) => RoomsApi(
    Dio(BaseOptions(baseUrl: 'http://test'))..httpClientAdapter = _Canned(body));

const _room = {'id': 'r1', 'name': '房', 'status': 'active'};

void main() {
  test('🔴 詳情的 you_are_admin 讀得到——它在頂層', () async {
    final d = await _api({
      'room': _room,
      'participants': [],
      'you_are_admin': true,
    }).detail('r1');
    expect(d.youAreAdmin, isTrue);
  });

  test('⚠️ `room` 裡沒有那個欄位——這正是誤用會踩到的地方', () async {
    final d = await _api({
      'room': _room,
      'participants': [],
      'you_are_admin': true,
    }).detail('r1');
    // 拿 `d.room.youAreAdmin` 判的話，管理員會被判成不是管理員
    expect(d.room.youAreAdmin, isFalse);
  });

  test('沒給就不是管理員——不要預設成 true', () async {
    final d = await _api({'room': _room, 'participants': []}).detail('r1');
    expect(d.youAreAdmin, isFalse);
  });
}
