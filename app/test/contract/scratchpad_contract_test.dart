@Tags(['contract'])
library;

import 'dart:io';

import 'package:chatroom_app/api/api_client.dart';
import 'package:chatroom_app/api/board_api.dart';
import 'package:chatroom_app/api/scratchpad_api.dart';
import 'package:chatroom_app/core/errors/api_exception.dart';
import 'package:chatroom_app/models/board.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

/// **打真 Hub 的契約測試：想法板與卡片追蹤。**
///
/// 這一組存在的理由跟 `board_contract_test` 一樣，但它守的那條縫今天特別
/// 寬——想法板與追蹤的每一個鍵名與參數位置，我都是**讀 Hub 原始碼**得到
/// 的，不是實測。而光是這一天我就在同一條路上猜錯三次：
///
/// | 我送的／讀的 | Hub 要的／給的 | 症狀 |
/// |---|---|---|
/// | `unread` | `unread_count` | 紅點永遠不亮，畫面就是「沒有未讀」 |
/// | `notice_ids` 放 body | 走 query | 一筆都沒標記，紅點繼續亮著 |
/// | `unresolve` 放 body | 走 query | 收不回來，而按鈕看起來成功了 |
///
/// 三個都不報錯。**所以「讀過原始碼」不算證據，跑過才算。**
///
/// ```
/// CHATROOM_TEST_URL=http://127.0.0.1:8788 \
/// CHATROOM_TEST_TOKEN=<server/.env 那把> \
///   flutter test test/contract
/// ```
void main() {
  final url = Platform.environment['CHATROOM_TEST_URL'] ?? '';
  final token = Platform.environment['CHATROOM_TEST_TOKEN'] ?? '';

  if (url.isEmpty || token.isEmpty) {
    test('契約測試需要一台 Hub（設 CHATROOM_TEST_URL / _TOKEN 才會跑）', () {
      markTestSkipped('未設定 CHATROOM_TEST_URL / CHATROOM_TEST_TOKEN');
    }, skip: false);
    return;
  }

  late Dio dio;
  late BoardsApi boards;
  late ScratchpadApi pads;
  late WatchApi watches;
  const sessionKey = 'claude-ui-pad-contract';

  setUpAll(() {
    dio = createApiDio(baseUrl: url, token: token, hostView: () => false);
    boards = BoardsApi(dio);
    pads = ScratchpadApi(dio);
    watches = WatchApi(dio);
  });

  tearDownAll(() => dio.close());

  Options h(String key) => Options(headers: {'X-Session-Key': key});

  Future<String> freshBoard(String label) async {
    final id = await boards.create(
        name: '契約測試 · $label', sessionKey: sessionKey);
    addTearDown(() async {
      try {
        await dio.delete<Map<String, dynamic>>('/api/boards/$id',
            queryParameters: {'session_key': sessionKey});
      } catch (_) {}
    });
    return id;
  }

  group('想法板', () {
    test('建一份、讀回來，段落帶得回 rev 與 can_edit', () async {
      final bid = await freshBoard('pad');
      final pid = await pads.create(bid,
          sessionKey: sessionKey, title: '想法', content: '第一段');
      final pad = await pads.fetch(bid, pid, sessionKey: sessionKey);
      expect(pad.title, '想法');
      expect(pad.blocks, hasLength(1));
      final b = pad.blocks.single;
      expect(b.content, '第一段');
      // rev 跟內容一起回來。分兩支 API 拿的話，中間那段時間就是一個
      // 看不見的競態窗口
      expect(b.rev, greaterThanOrEqualTo(1));
      // can_edit 是伺服器算的守門結果——**自己是作者，所以要是 true**。
      // 讀不到就當唯讀，那時整份板會無故不能編，而使用者找不到原因
      expect(b.canEdit, isTrue);
      expect(b.authorActorKey, sessionKey);
    });

    test('清單帶得回 block_count 與 unresolved_notes', () async {
      final bid = await freshBoard('pad-list');
      final pid = await pads.create(bid,
          sessionKey: sessionKey, title: '清單', content: '一');
      final list = await pads.list(bid, sessionKey: sessionKey);
      final mine = list.where((p) => p.id == pid);
      expect(mine, hasLength(1));
      expect(mine.single.blockCount, 1);
      // unresolved_notes 是「有人對你的段落提了意見」的唯一線索
      expect(mine.single.unresolvedNotes, 0);
    });

    test('rev 對不上就寫不進去，而 409 要帶現值', () async {
      final bid = await freshBoard('pad-cas');
      final pid = await pads.create(bid,
          sessionKey: sessionKey, title: 'CAS', content: '原本的');
      final pad = await pads.fetch(bid, pid, sessionKey: sessionKey);
      final b = pad.blocks.single;

      await pads.writeBlock(bid, pid, b.id,
          sessionKey: sessionKey, content: '改過一次', rev: b.rev);

      // 拿舊的 rev 再寫一次＝另一個人拿著過期的版本按下存檔
      try {
        await pads.writeBlock(bid, pid, b.id,
            sessionKey: sessionKey, content: '拿舊版蓋', rev: b.rev);
        fail('舊的 rev 應該要被擋下來');
      } on ApiException catch (e) {
        expect(e.code, 'scratchpad_block_stale');
        // 🔴 **這兩個是衝突畫面唯一的材料。** 少了 content，UI 就只能
        // 「自動用伺服器版蓋掉輸入框」——那等於把 CAS 防住的資料遺失
        // 原封不動搬到 client 上
        expect(e.detail['content'], '改過一次');
        expect(e.detail['rev'], isA<int>());
      }
    });

    test('註解掛得上去，也標得回已處理', () async {
      final bid = await freshBoard('pad-note');
      final pid = await pads.create(bid,
          sessionKey: sessionKey, title: '註解', content: '被評論的段落');
      final b0 = (await pads.fetch(bid, pid, sessionKey: sessionKey))
          .blocks
          .single;

      await pads.addNote(bid, pid, b0.id,
          sessionKey: sessionKey, content: '這段要拆');
      final withNote = (await pads.fetch(bid, pid, sessionKey: sessionKey))
          .blocks
          .single;
      expect(withNote.notes, hasLength(1));
      expect(withNote.openNotes, hasLength(1));

      final noteId = withNote.notes.single.id;
      // ⚠️ unresolve 走 query。放 body 的話 Hub 讀到預設值，**不報錯**，
      // 只是收不回來——而按鈕看起來成功了
      final resolved = await pads.resolveNote(bid, pid, noteId,
          sessionKey: sessionKey);
      expect(resolved, isTrue);
      final after = (await pads.fetch(bid, pid, sessionKey: sessionKey))
          .blocks
          .single;
      expect(after.notes.single.resolved, isTrue);
      expect(after.openNotes, isEmpty);

      // 收回：標錯了要有路可以退
      await pads.resolveNote(bid, pid, noteId,
          sessionKey: sessionKey, unresolve: true);
      final undone = (await pads.fetch(bid, pid, sessionKey: sessionKey))
          .blocks
          .single;
      expect(undone.openNotes, hasLength(1),
          reason: 'unresolve 若走錯位置，這裡仍會是 0，而畫面上看不出差別');
    });

    test('agent 排不動段落——這條我原本不知道', () async {
      // 🔴 這一條是這組測試抓到的**契約事實**，不是 bug：Hub 只讓人類重排，
      // 理由是「排序會改變別人那段話的上下文，那與改寫是同一類的事」。
      //
      // ⚠️ 我還沒做重排的 UI。做的時候必須照這條走——**agent 身分不給拖曳
      // 把手**，而不是讓它拖完才拿 403。留著這條當提醒：Hub 哪天放寬了，
      // 它會由紅告訴我那個限制沒了。
      final bid = await freshBoard('pad-order');
      final pid = await pads.create(bid,
          sessionKey: sessionKey, title: '排序', content: 'A');
      await pads.addBlock(bid, pid, sessionKey: sessionKey, content: 'B');
      final pad = await pads.fetch(bid, pid, sessionKey: sessionKey);
      expect(pad.blocks.map((b) => b.content), ['A', 'B']);

      await expectLater(
        pads.reorder(bid, pid,
            sessionKey: sessionKey,
            blockIds: pad.blocks.map((b) => b.id).toList().reversed.toList(),
            rev: pad.rev),
        throwsA(predicate((e) => e is ApiException && e.code == 'human_only')),
      );
    });
  });

  group('卡片追蹤', () {
    /// 追蹤要有落點，所以這一組需要一間活著的掛接房。
    Future<({String boardId, String taskId, String participantId,
             String roomId})> boardWithTask(String label) async {
      final res = await dio.post<Map<String, dynamic>>('/api/rooms',
          data: {'name': '契約測試 · $label', 'session_key': sessionKey});
      final roomId = res.data!['id'] as String;
      final joined = await dio
          .post<Map<String, dynamic>>('/api/rooms/$roomId/join', data: {
        'kind': 'claude',
        'session_key': sessionKey,
        'preferred_name': '契約測試員',
      });
      addTearDown(() async {
        try {
          await dio.delete<Map<String, dynamic>>('/api/rooms/$roomId',
              options: h(sessionKey));
        } catch (_) {}
      });
      final bid = await freshBoard(label);
      await boards.attachRoom(bid, roomId, sessionKey: sessionKey);
      final task = await dio.post<Map<String, dynamic>>(
          '/api/boards/$bid/tasks',
          data: {'title': '被追蹤的卡'},
          options: h(sessionKey));
      return (
        boardId: bid,
        roomId: roomId,
        taskId: task.data!['id'] as String,
        // 推狀態走 X-Participant-Id，不是 session key——**狀態轉移有自己的
        // 守門**，所以它不在 PATCH /tasks 那條路上
        participantId: joined.data!['participant_id'] as String,
      );
    }

    test('追蹤與取消都回得出 watcher_count', () async {
      final t = await boardWithTask('watch');
      final n = await watches.watch(t.boardId,
          sessionKey: sessionKey, itemKind: 'task', itemId: t.taskId);
      expect(n, 1);
      // ⚠️ item_kind / item_id 走 query（DELETE 沒有 body）
      final after = await watches.unwatch(t.boardId,
          sessionKey: sessionKey, itemKind: 'task', itemId: t.taskId);
      expect(after, 0);
    });

    test('watching / watcher_count 補得到卡上——按鈕的狀態靠它', () async {
      final t = await boardWithTask('watch-delta');
      await watches.watch(t.boardId,
          sessionKey: sessionKey, itemKind: 'task', itemId: t.taskId);
      final d = await boards.fetch(t.boardId, sessionKey: sessionKey);
      final snap = const BoardSnapshot().merge(d);
      final card = snap.tasks[t.taskId];
      expect(card, isNotNull);
      // 不在 delta 上的話，我只剩「按下去之後自己樂觀改狀態」一條路，
      // 而那會在失敗時顯示成功
      expect(card!.watching, isTrue);
      expect(card.watcherCount, 1);
    });

    test('卡完成時追蹤者收到一筆，而 unread_count 讀得出來', () async {
      // ⚠️ **追蹤的人與完成的人必須是兩個**。Hub 刻意不通知造成變更的
      // 那個人（「他就是按下那個按鈕的人」），所以自己追自己完成會拿到
      // 一個空的收件匣——而那看起來與「通知根本沒發出來」一模一樣。
      // 我第一版就是這樣寫的，收件匣空了才回頭去讀 Hub 才知道
      const guest = 'claude-ui-pad-contract-guest';
      final t = await boardWithTask('watch-notice');
      await dio.post<Map<String, dynamic>>(
          '/api/rooms/${t.roomId}/join',
          data: {
            'kind': 'claude',
            'session_key': guest,
            'preferred_name': '契約測試客',
          });
      // 匯入才會讓 guest 成為板成員——追蹤要板成員身分
      await boards.attachRoom(t.boardId, t.roomId,
          sessionKey: sessionKey, importMembers: true);
      await watches.watch(t.boardId,
          sessionKey: guest, itemKind: 'task', itemId: t.taskId);

      // ⚠️ **todo 不能直接跳 done**（Hub 回 409 invalid_transition）。
      // 那個 409 會附上 allowed，照它走就好——不必自己記一份轉移表
      for (final st in ['in_progress', 'done']) {
        await dio.post<Map<String, dynamic>>(
            '/api/board/tasks/${t.taskId}/status',
            data: {'status': st},
            options: Options(headers: {'X-Participant-Id': t.participantId}));
      }

      final inbox = await watches.notices(
          sessionKey: guest, boardId: t.boardId, unreadOnly: false);
      expect(inbox.notices, isNotEmpty,
          reason: '追蹤者要收到——漏送的話這個功能等於不存在');
      final one = inbox.notices.first;
      // 🔴 event_type 我猜錯過：Hub 寫 task_done（app.py:4321）
      expect(one.eventType, 'task_done');
      expect(one.itemId, t.taskId);
      // 🔴 `unread_count` 不是 `unread`。差一個字，紅點永遠不亮，
      // 而畫面看起來就是「沒有未讀」
      expect(inbox.unread, greaterThan(0));

      // ⚠️ notice_ids 走 query。放 body 的話一筆都不會被標記，
      // 而回應仍然 200——紅點繼續亮著
      final marked =
          await watches.markRead(sessionKey: guest, noticeIds: [one.id]);
      expect(marked, 1,
          reason: '回 0 表示參數放錯位置了，而那與「本來就沒有未讀」同形');
    });

    test('沒在追的人收不到——多送的話這個功能就沒有意義', () async {
      final t = await boardWithTask('watch-quiet');
      final before = await watches.notices(
          sessionKey: sessionKey, boardId: t.boardId, unreadOnly: false);
      for (final st in ['in_progress', 'done']) {
        await dio.post<Map<String, dynamic>>(
            '/api/board/tasks/${t.taskId}/status',
            data: {'status': st},
            options: Options(headers: {'X-Participant-Id': t.participantId}));
      }
      final after = await watches.notices(
          sessionKey: sessionKey, boardId: t.boardId, unreadOnly: false);
      expect(after.notices.length, before.notices.length,
          reason: '沒有人追蹤這張卡，不該有任何一筆落地');
    });

    test('零掛接房的板追不了——明確擋下，不是追得成然後永遠等不到', () async {
      final bid = await freshBoard('watch-noroom');
      await expectLater(
        watches.watch(bid,
            sessionKey: sessionKey, itemKind: 'task', itemId: 'whatever'),
        throwsA(isA<ApiException>()),
      );
    });
  });

  group('Library 的 delivery_mode', () {
    test('有活著的房時不是 inbox_only', () async {
      final res = await dio.post<Map<String, dynamic>>('/api/rooms',
          data: {'name': '契約測試 · delivery', 'session_key': sessionKey});
      final roomId = res.data!['id'] as String;
      addTearDown(() async {
        try {
          await dio.delete<Map<String, dynamic>>('/api/rooms/$roomId',
              options: h(sessionKey));
        } catch (_) {}
      });
      final bid = await freshBoard('delivery');
      await boards.attachRoom(bid, roomId, sessionKey: sessionKey);

      final list = await boards.list(sessionKey: sessionKey);
      final card = list.where((b) => b.id == bid);
      expect(card, hasLength(1));
      // 這一欄是 Hub 算好的**現值**。讀不到就會退回用房數推，
      // 而那是在猜 Hub 的規則
      expect(card.single.deliveryMode, isNotEmpty,
          reason: 'delivery_mode 缺了的話，降級狀態畫不出來');
      expect(card.single.inboxOnly, isFalse);
      expect(card.single.liveRoomCount, greaterThan(0));
    });
  });
}
