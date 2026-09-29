import 'dart:async';

import 'package:chatroom_app/api/board_api.dart';
import 'package:chatroom_app/api/rooms_api.dart';
import 'package:chatroom_app/core/config/app_settings.dart';
import 'package:chatroom_app/models/board.dart';
import 'package:chatroom_app/models/room.dart';
import 'package:chatroom_app/state/app_providers.dart';
import 'package:chatroom_app/state/board_providers.dart';
import 'package:chatroom_app/state/messages_providers.dart';
import 'package:chatroom_app/state/rooms_providers.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 成員列的定期輪詢不可以帶著任務板重拉。
///
/// 🔴 聊天室每隔一段時間 invalidate 一次 `roomDetailProvider` 來刷新成員列。
/// `boardParticipantIdProvider` 原本 `await` 那份詳情的 `.future`——詳情
/// 一重建它就跟著重建，`boardProvider` 又 watch 它 ⇒ **每一次輪詢都打一次
/// GET /board**，畫面也跟著 reload。
///
/// 任務板該動的時機只有兩個：WS 水位變了、自己動作之後 invalidate。
class _CountingApi extends BoardApi {
  _CountingApi() : super(Dio());

  int fetches = 0;

  @override
  Future<BoardDelta> fetch(String roomId,
      {int afterBoardSeq = 0, String? participantId}) async {
    fetches++;
    return BoardDelta.fromJson({
      'board_seq': 10,
      'full': afterBoardSeq == 0,
      'board_id': 'b1',
      'objectives': const [],
      'tasks': const [],
    });
  }
}

Room _room(String status) => Room(
      id: 'r1',
      name: '測試房',
      topic: '',
      status: status,
      createdAt: '2026-09-01T00:00:00+00:00',
    );

/// 讓排好的重建跑完。一次 microtask 不夠：pid 那層重建之後 board 才會跟上
Future<void> _settle() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SettingsRepository settings;
  late _CountingApi api;
  late StreamController<int> signal;
  late ProviderContainer c;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    settings = SettingsRepository(await SharedPreferences.getInstance());
    api = _CountingApi();
    signal = StreamController<int>.broadcast();
    c = ProviderContainer(
      overrides: [
        settingsRepoProvider.overrideWithValue(settings),
        boardApiProvider.overrideWithValue(api),
        // 內容不變的詳情：輪詢前後同一份房、同一個狀態
        roomDetailProvider('r1').overrideWith((ref) async =>
            RoomDetail(room: _room('active'), participants: const [])),
        identityProvider('r1').overrideWith(
            (ref) async => (participantId: 'p1', displayName: '人類')),
        boardSignalProvider('r1').overrideWith((ref) => signal.stream),
      ],
    );
    addTearDown(() async {
      c.dispose();
      await signal.close();
    });
  });

  test('🔴 成員輪詢 invalidate 房間詳情，板不會再拉一次', () async {
    c.listen(boardProvider('r1'), (_, _) {}, onError: (_, _) {});
    await c.read(boardProvider('r1').future);
    expect(api.fetches, 1);

    // 等同 chat_screen 的成員輪詢做的事
    c.invalidate(roomDetailProvider('r1'));
    await c.read(roomDetailProvider('r1').future);
    await _settle();
    await c.read(boardProvider('r1').future);

    expect(api.fetches, 1,
        reason: '房間資料與 participant 都沒變，任務板沒有理由重拉');
  });

  test('WS 水位變了照樣重拉——切斷的只是輪詢那條', () async {
    c.listen(boardProvider('r1'), (_, _) {}, onError: (_, _) {});
    await c.read(boardProvider('r1').future);
    expect(api.fetches, 1);

    signal.add(11);
    await _settle();
    await c.read(boardProvider('r1').future);

    expect(api.fetches, 2);
  });
}
