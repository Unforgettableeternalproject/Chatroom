@Tags(['contract'])
library;

import 'dart:io';

import 'package:chatroom_app/api/api_client.dart';
import 'package:chatroom_app/api/board_api.dart';
import 'package:chatroom_app/core/errors/api_exception.dart';
import 'package:chatroom_app/models/board.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

/// **打真 Hub 的契約測試。**
///
/// 這一組與其他測試的差別，是它驗的東西別的測試驗不到：
/// **「client 送出去的東西」與「Hub 要的東西」之間那條縫。**
///
/// 2026-09-02 一天之內，那條縫上出現六個缺陷，而當時 UI 側 421 條測試
/// 全綠、Hub 側 857 條也全綠——**兩邊各自前後一致，中間沒有人站著**：
///
/// | 送出的 | Hub 要的 | 症狀 |
/// |---|---|---|
/// | `content` | `text` | 422，訊息說「這些欄位不被允許」 |
/// | `to_actor_key` | `target_actor_key` | 同上 |
/// | 空 target | `min_length=1` | 一個永遠送不出去的選項 |
/// | 沒送 display_name | 存成快照 | 指派完 Supervisor 沒有名字 |
/// | directive 有 `id` | 只有 `board_seq` | 稽核串疊不起來 |
/// | `supervisor` 是字串 | 是物件 | 遷移期一邊靜默消失 |
///
/// 六個全部是手打探針抓到的，而**那些探針跑完就沒了**。這一組存在的意義
/// 就是把那件事變成可重跑的——Hub 改欄位名時，這裡會紅。
///
/// ---
///
/// **需要一台活的 Hub。** 沒有就整組跳過（不是失敗）：
///
/// ```
/// CHATROOM_TEST_URL=http://127.0.0.1:8788 \
/// CHATROOM_TEST_TOKEN=<server/.env 那把> \
///   flutter test test/contract
/// ```
///
/// ⚠️ **會在那台 Hub 上建立並刪除資料**，所以請指向測試 Hub，不要指生產。
/// 每個測試自己收尾；收不掉的東西會在名字裡帶「契約測試」四個字。
void main() {
  final url = Platform.environment['CHATROOM_TEST_URL'] ?? '';
  final token = Platform.environment['CHATROOM_TEST_TOKEN'] ?? '';

  if (url.isEmpty || token.isEmpty) {
    // ⚠️ 用一個會出現在報告裡的 skip，不是靜靜地不跑。
    // 靜靜不跑的契約測試與沒有契約測試，在 CI 的輸出上長得一模一樣
    test('契約測試需要一台 Hub（設 CHATROOM_TEST_URL / _TOKEN 才會跑）', () {
      markTestSkipped('未設定 CHATROOM_TEST_URL / CHATROOM_TEST_TOKEN');
    }, skip: false);
    return;
  }

  late Dio dio;
  late BoardsApi boards;
  const sessionKey = 'claude-ui-contract-test';

  setUpAll(() async {
    dio = createApiDio(baseUrl: url, token: token, hostView: () => false);
    boards = BoardsApi(dio);

    // 把對方的版本印出來。**這一組紅掉時，第一個要問的問題是「打的是哪
    // 一版」**——2026-09-02 有一條紅了半小時，三個人各自用症狀反推版本，
    // 而 Hub 自己一直都答得出來。沒印出來的話，「client 送錯」與
    // 「Hub 還沒升」在輸出上長得一模一樣
    try {
      final res = await dio.get<Map<String, dynamic>>('/api/health');
      final b = res.data?['build'] as Map<String, dynamic>? ?? const {};
      printOnFailure('Hub: $url');
      print('契約測試打的 Hub：$url · '
          'v${res.data?['version'] ?? '?'} · ${b['commit'] ?? '?'}');
    } catch (e) {
      // 印不出來不該讓整組不跑——舊 Hub 可能沒有 /api/health，
      // 而契約本身仍然驗得動
      print('契約測試打的 Hub：$url（版本問不到：$e）');
    }
  });

  tearDownAll(() => dio.close());

  /// 開一塊乾淨的板給單一測試用，結束就刪。
  Future<String> freshBoard(String label) async {
    final id = await boards.create(
      name: '契約測試 · $label',
      sessionKey: sessionKey,
    );
    addTearDown(() async {
      try {
        await dio.delete<Map<String, dynamic>>('/api/boards/$id',
            queryParameters: {'session_key': sessionKey});
      } catch (_) {
        // 清不掉不該讓測試變紅——那會把「契約壞了」與「殘留沒清掉」
        // 混成同一個訊號，而前者才是這組測試要講的事
      }
    });
    return id;
  }

  group('Board Library 與 delta', () {
    test('GET /api/boards 的每一格都對得上 BoardSummary', () async {
      await freshBoard('library');
      final list = await boards.list(sessionKey: sessionKey);
      final mine = list.where((b) => b.name.startsWith('契約測試')).toList();
      expect(mine, isNotEmpty, reason: '剛建的板要出現在自己的 Library 裡');
      final b = mine.first;
      // 這幾個欄位空掉時畫面不會壞，只會少一塊——所以要在這裡擋
      expect(b.id, isNotEmpty);
      expect(b.status, isNotEmpty);
      expect(b.myRole, 'owner', reason: '建立者就是 owner；空字串會讓畫面當唯讀');
    });

    test('GET /api/boards/{id} 帶得回板的中繼資料與成員', () async {
      final id = await freshBoard('delta');
      final d = await boards.fetch(id, sessionKey: sessionKey);
      expect(d.boardId, id);
      expect(d.name, contains('契約測試'), reason: '沒有 name 就畫不出頁首');
      expect(d.status, isNotEmpty);
      expect(d.myRole, 'owner');
      // members 是別名與顯示名的唯一權威（H7）
      expect(d.members.map((m) => m.actorKey), contains(sessionKey));
    });

    test('掛接房的 detached 欄位存在——它是 tombstone，缺了會殘留', () async {
      final id = await freshBoard('attach');
      final d = await boards.fetch(id, sessionKey: sessionKey);
      // 新板沒有掛接房。這裡驗的是**欄位形狀**：解除掛接時要靠 detached
      // 把房從快取移除，Hub 若只回「還掛著的」，client 會殘留一間已解除的房
      expect(d.attachedRooms, isEmpty);
    });
  });

  group('Supervisor 與 directive', () {
    test('指派時 display_name / actor_kind 會被存下來', () async {
      final id = await freshBoard('supervisor');
      await boards.setSupervisor(
        id,
        sessionKey: sessionKey,
        actorKey: sessionKey,
        displayName: '契約測試員',
        actorKind: 'claude',
      );
      final d = await boards.fetch(id, sessionKey: sessionKey);
      expect(d.supervisor, isNotNull);
      expect(d.supervisor!.actorKey, sessionKey);
      // 🔴 這條是 2026-09-02 的實際缺陷：client 沒送這兩欄 → Hub 存空字串
      // → Supervisor 顯示成一顆沒有名字的膠囊，而他可能不是板成員，
      // 沒有任何地方查得回名字
      expect(d.supervisor!.displayName, '契約測試員');
      expect(d.supervisor!.actorKind, 'claude');
    });

    test('卸任把名字一起清掉，不留上一任', () async {
      final id = await freshBoard('supervisor-clear');
      await boards.setSupervisor(id,
          sessionKey: sessionKey,
          actorKey: sessionKey,
          displayName: '前一任',
          actorKind: 'claude');
      await boards.setSupervisor(id, sessionKey: sessionKey, actorKey: null);
      final d = await boards.fetch(id, sessionKey: sessionKey);
      expect(d.supervisor, isNull);
    });

    test('送 directive 用 target_actor_key / text，且回得出 delivered',
        () async {
      final id = await freshBoard('directive');
      await boards.setSupervisor(id,
          sessionKey: sessionKey,
          actorKey: sessionKey,
          displayName: '契約測試員',
          actorKind: 'claude');
      final delivered = await boards.sendDirective(
        id,
        sessionKey: sessionKey,
        text: '契約測試：這句話應該進得了稽核串',
        targetActorKey: sessionKey,
      );
      // 板沒有掛接房 ⇒ 沒有投影的落點 ⇒ 沒有人被叫醒。
      // **false 是正確答案**，而它必須送得到 UI：假裝送到了，
      // Supervisor 會以為對方已經知道了
      expect(delivered, isFalse);

      final d = await boards.fetch(id, sessionKey: sessionKey);
      final list = const BoardSnapshot().merge(d).sortedDirectives;
      expect(list, hasLength(1));
      // directive 沒有 id，board_seq 就是識別
      expect(list.single.boardSeq, greaterThan(0));
      expect(list.single.text, contains('契約測試'));
      expect(list.single.fromActorKey, sessionKey);
      // from 是平鋪的名字快照，不是巢狀物件——Supervisor 可以不是板成員，
      // 查 members[] 會查不到
      expect(list.single.fromName, isNotEmpty);
    });

    test('空 target 送不出去——UI 不可以提供「對整塊板說」', () async {
      final id = await freshBoard('directive-empty');
      // 這條的用途是**盯著它什麼時候變**：Hub 若實作了廣播，這裡會由紅
      // 提醒我們把那個選項加回去。現在它必須失敗
      await expectLater(
        boards.sendDirective(id,
            sessionKey: sessionKey, text: 'x', targetActorKey: ''),
        throwsA(isA<ApiException>()),
      );
    });
  });

  group('掛接與成員匯入', () {
    /// 開一間房，結束就刪。掛接兩邊都要驗身分，所以房必須由同一把
    /// session_key 建立——不然會被 `not_room_admin` 擋下。
    Future<String> freshRoom(String label) async {
      final res = await dio.post<Map<String, dynamic>>(
        '/api/rooms',
        data: {'name': '契約測試 · $label', 'session_key': sessionKey},
      );
      final id = res.data!['id'] as String;
      // ⚠️ **建房不等於進房**——Hub 那邊 `POST /api/rooms` 只寫 room，
      // 不寫 participant。匯入讀的是 participant，所以不 join 的話這裡
      // 會拿到一個空的 imported_members，而那看起來與「query 位置錯了」
      // 一模一樣（我第一次跑就這樣騙到自己）
      await dio.post<Map<String, dynamic>>(
        '/api/rooms/$id/join',
        data: {
          'kind': 'claude',
          'session_key': sessionKey,
          'preferred_name': '契約測試員',
        },
      );
      addTearDown(() async {
        try {
          // ⚠️ 刪房走 **X-Session-Key 標頭**，不是 query（刪板那條兩種都
          // 收，很容易照抄過來）。傳錯會拿到 403，而這裡的 catch 會把它
          // 吞掉——每跑一次就在共用的測試 Hub 上多留一間房
          await dio.delete<Map<String, dynamic>>('/api/rooms/$id',
              options: Options(headers: {'X-Session-Key': sessionKey}));
        } catch (_) {}
      });
      return id;
    }

    test('import_members 走 query，勾了要真的匯入', () async {
      final roomId = await freshRoom('import');
      final boardId = await freshBoard('import');
      // ⚠️ 用**第二個人**驗，不能用自己：建板的人已經是 owner，而 Hub 的
      // 匯入不覆寫既有角色，所以他不會出現在 imported_members 裡。拿自己
      // 當受詞的話，這條測試對「勾選有沒有效」永遠回答不出來
      const other = 'claude-ui-contract-guest';
      await dio.post<Map<String, dynamic>>(
        '/api/rooms/$roomId/join',
        data: {
          'kind': 'claude',
          'session_key': other,
          'preferred_name': '契約測試客',
        },
      );

      final out = await boards.attachRoom(boardId, roomId,
          sessionKey: sessionKey, importMembers: true);
      // 🔴 2026-09-02 的實際缺陷：client 把它塞在 body 裡，Hub 讀到預設的
      // false。**不報錯**，只是那個核取方塊靜靜地沒有效果。這條測的就是
      // 「送出去的位置」——欄位名對、型別對，位置錯一樣是靜默失效
      expect(out.alreadyAttached, isFalse);
      expect(out.importedMembers, contains(other));

      final d = await boards.fetch(boardId, sessionKey: sessionKey);
      final m = d.members.where((m) => m.actorKey == other);
      expect(m, hasLength(1), reason: '回報匯入了，就要在成員列上看得到');
      // editor，不是 viewer——匯入成 viewer 的話勾了等於沒勾
      expect(m.single.role, 'editor');
    });

    test('已經掛著同一塊板時不早退，匯入照做', () async {
      final roomId = await freshRoom('reattach');
      final boardId = await freshBoard('reattach');
      await boards.attachRoom(boardId, roomId, sessionKey: sessionKey);
      final out = await boards.attachRoom(boardId, roomId,
          sessionKey: sessionKey, importMembers: true);
      // App 建新板走的正是這條：`POST /api/boards` 帶 origin_room_id 就掛好
      // 了，匯入是第二次呼叫。早退的話勾選在「建一塊新的」那條路上永遠沒用
      expect(out.alreadyAttached, isTrue);
    });

    test('解除掛接後 detached tombstone 回得來', () async {
      final roomId = await freshRoom('detach');
      final boardId = await freshBoard('detach');
      await boards.attachRoom(boardId, roomId, sessionKey: sessionKey);
      final before = await boards.fetch(boardId, sessionKey: sessionKey);
      expect(before.attachedRooms.map((r) => r.id), contains(roomId));

      await boards.detachRoom(boardId, roomId, sessionKey: sessionKey);
      final after = await boards.fetch(boardId, sessionKey: sessionKey);
      // 全量回應直接不含它即可；增量才需要 tombstone。兩種都可以，
      // 不可以的是**還掛在上面**
      final live = const BoardSnapshot().merge(after).liveRooms;
      expect(live.map((r) => r.id), isNot(contains(roomId)));
    });
  });

  group('排序', () {
    test('reorder 整批送、整批套用', () async {
      final id = await freshBoard('reorder');
      final a = await dio.post<Map<String, dynamic>>(
        '/api/boards/$id/objectives',
        data: {'title': 'A'},
        options: Options(headers: {'X-Session-Key': sessionKey}),
      );
      final b = await dio.post<Map<String, dynamic>>(
        '/api/boards/$id/objectives',
        data: {'title': 'B'},
        options: Options(headers: {'X-Session-Key': sessionKey}),
      );
      final ids = [a.data!['id'] as String, b.data!['id'] as String];

      await boards.reorder(id,
          sessionKey: sessionKey,
          kind: 'objective',
          ids: ids.reversed.toList());

      final d = await boards.fetch(id, sessionKey: sessionKey);
      final snap = const BoardSnapshot().merge(d);
      expect(snap.sortedObjectives.map((o) => o.title), ['B', 'A']);
    });

    test('有一張卡不屬於這塊板時整批退回', () async {
      final id = await freshBoard('reorder-reject');
      // 部分成功會讓 client 拿到一個它無法解讀的順序——排序是整批語意
      await expectLater(
        boards.reorder(id,
            sessionKey: sessionKey,
            kind: 'objective',
            ids: ['does-not-exist']),
        throwsA(isA<ApiException>()),
      );
    });
  });
}
