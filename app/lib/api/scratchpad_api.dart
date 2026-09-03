import 'package:dio/dio.dart';

import '../models/scratchpad.dart';
import 'api_client.dart';

/// 想法板與卡片追蹤。
///
/// ⚠️ 一律走 `X-Session-Key` **標頭**。`/api/rooms` 那組是 query，照抄過來
/// 會拿到 400 `session_key_required`，而那個訊息讀起來像身分問題，
/// 不像「你放錯位置了」（2026-09-02 踩過一次）。
class ScratchpadApi {
  ScratchpadApi(this._dio);

  final Dio _dio;

  Options _h(String sessionKey) =>
      Options(headers: {'X-Session-Key': sessionKey});

  /// 這塊板上有哪些想法板。不回內容。
  Future<List<ScratchpadSummary>> list(
    String boardId, {
    required String sessionKey,
  }) =>
      unwrap(() async {
        final res = await _dio.get<Map<String, dynamic>>(
          '/api/boards/$boardId/scratchpads',
          options: _h(sessionKey),
        );
        final raw = res.data?['scratchpads'] as List<dynamic>? ?? const [];
        return [
          for (final p in raw)
            ScratchpadSummary.fromJson(p as Map<String, dynamic>),
        ];
      });

  /// 讀一份：段落 + 每段的註解 + 每段自己的 rev。
  Future<Scratchpad> fetch(
    String boardId,
    String padId, {
    required String sessionKey,
  }) =>
      unwrap(() async {
        final res = await _dio.get<Map<String, dynamic>>(
          '/api/boards/$boardId/scratchpads/$padId',
          options: _h(sessionKey),
        );
        return Scratchpad.fromJson(res.data ?? const {});
      });

  /// 開一份新的。[content] 給了就變成第一個段落。
  Future<String> create(
    String boardId, {
    required String sessionKey,
    required String title,
    String content = '',
  }) =>
      unwrap(() async {
        final res = await _dio.post<Map<String, dynamic>>(
          '/api/boards/$boardId/scratchpads',
          data: {'title': title, 'content': content},
          options: _h(sessionKey),
        );
        return (res.data?['id'] as String?) ?? '';
      });

  Future<void> deletePad(
    String boardId,
    String padId, {
    required String sessionKey,
  }) =>
      unwrap(() async {
        await _dio.delete<Map<String, dynamic>>(
          '/api/boards/$boardId/scratchpads/$padId',
          options: _h(sessionKey),
        );
      });

  /// 加一個段落。[afterBlockId] 空的就接在最後。
  Future<String> addBlock(
    String boardId,
    String padId, {
    required String sessionKey,
    required String content,
    String afterBlockId = '',
  }) =>
      unwrap(() async {
        final res = await _dio.post<Map<String, dynamic>>(
          '/api/boards/$boardId/scratchpads/$padId/blocks',
          data: {'content': content, 'after_block_id': afterBlockId},
          options: _h(sessionKey),
        );
        return (res.data?['id'] as String?) ?? '';
      });

  /// 改一個段落。
  ///
  /// ⚠️ [rev] **必填、沒有預設值**。給了預設值等於「不知道就當作沒人改過」，
  /// 而那正是 CAS 要擋的那件事。改不動時 Hub 回 409 `scratchpad_block_stale`
  /// 並附上**現值的 content 與 rev**——那兩個是衝突畫面唯一的材料。
  Future<int> writeBlock(
    String boardId,
    String padId,
    String blockId, {
    required String sessionKey,
    required String content,
    required int rev,
  }) =>
      unwrap(() async {
        final res = await _dio.put<Map<String, dynamic>>(
          '/api/boards/$boardId/scratchpads/$padId/blocks/$blockId',
          data: {'content': content, 'rev': rev},
          options: _h(sessionKey),
        );
        return (res.data?['rev'] as int?) ?? rev;
      });

  Future<void> deleteBlock(
    String boardId,
    String padId,
    String blockId, {
    required String sessionKey,
  }) =>
      unwrap(() async {
        await _dio.delete<Map<String, dynamic>>(
          '/api/boards/$boardId/scratchpads/$padId/blocks/$blockId',
          options: _h(sessionKey),
        );
      });

  /// 重排段落。[blockIds] 要是**完整且唯一**的那一份。
  ///
  /// [rev] 是**這份想法板的結構版本**，不是某一段的。
  Future<int> reorder(
    String boardId,
    String padId, {
    required String sessionKey,
    required List<String> blockIds,
    required int rev,
  }) =>
      unwrap(() async {
        final res = await _dio.post<Map<String, dynamic>>(
          '/api/boards/$boardId/scratchpads/$padId/reorder',
          data: {'block_ids': blockIds, 'rev': rev},
          options: _h(sessionKey),
        );
        return (res.data?['rev'] as int?) ?? rev;
      });

  /// 對某一段留一則註解。**agent 對人類段落唯一能做的事。**
  Future<void> addNote(
    String boardId,
    String padId,
    String blockId, {
    required String sessionKey,
    required String content,
  }) =>
      unwrap(() async {
        await _dio.post<Map<String, dynamic>>(
          '/api/boards/$boardId/scratchpads/$padId/blocks/$blockId/notes',
          data: {'content': content},
          options: _h(sessionKey),
        );
      });

  /// 把一則註解標成已處理（[unresolve] 收回）。
  ///
  /// ⚠️ `unresolve` 走 **query**（Hub 那端是 `unresolve: bool = False`，
  /// 沒有 BaseModel 包著的原始型別一律收 query）。
  ///
  /// 有這條之前，「N 則未處理」只會往上長——**有狀態就要有轉移，
  /// 不然那個狀態是假的**。
  Future<bool> resolveNote(
    String boardId,
    String padId,
    String noteId, {
    required String sessionKey,
    bool unresolve = false,
  }) =>
      unwrap(() async {
        final res = await _dio.post<Map<String, dynamic>>(
          '/api/boards/$boardId/scratchpads/$padId/notes/$noteId/resolve',
          queryParameters: {if (unresolve) 'unresolve': true},
          options: _h(sessionKey),
        );
        return (res.data?['resolved'] as bool?) ?? !unresolve;
      });
}

/// 卡片追蹤與跨板收件匣。
class WatchApi {
  WatchApi(this._dio);

  final Dio _dio;

  Options _h(String sessionKey) =>
      Options(headers: {'X-Session-Key': sessionKey});

  /// 追蹤一張卡。回傳這張卡現在有幾個人在等。
  Future<int> watch(
    String boardId, {
    required String sessionKey,
    required String itemKind,
    required String itemId,
  }) =>
      unwrap(() async {
        final res = await _dio.post<Map<String, dynamic>>(
          '/api/boards/$boardId/watches',
          data: {'item_kind': itemKind, 'item_id': itemId},
          options: _h(sessionKey),
        );
        return (res.data?['watcher_count'] as int?) ?? 0;
      });

  /// 取消追蹤。
  ///
  /// ⚠️ item_kind / item_id 走 **query**（DELETE 沒有 body）。
  /// 已經寫進收件匣的通知不會被撤回——那是已經發生的事。
  Future<int> unwatch(
    String boardId, {
    required String sessionKey,
    required String itemKind,
    required String itemId,
  }) =>
      unwrap(() async {
        final res = await _dio.delete<Map<String, dynamic>>(
          '/api/boards/$boardId/watches',
          queryParameters: {'item_kind': itemKind, 'item_id': itemId},
          options: _h(sessionKey),
        );
        return (res.data?['watcher_count'] as int?) ?? 0;
      });

  /// 我的追蹤收件匣。**跨板**——「我在等的東西完成了嗎」不分板。
  Future<({List<WatchNotice> notices, int unread})> notices({
    required String sessionKey,
    bool unreadOnly = true,
    String boardId = '',
  }) =>
      unwrap(() async {
        final res = await _dio.get<Map<String, dynamic>>(
          '/api/board/notices',
          queryParameters: {
            'unread_only': unreadOnly,
            if (boardId.isNotEmpty) 'board_id': boardId,
          },
          options: _h(sessionKey),
        );
        final raw = res.data?['notices'] as List<dynamic>? ?? const [];
        return (
          notices: [
            for (final n in raw)
              WatchNotice.fromJson(n as Map<String, dynamic>),
          ],
          // ⚠️ 是 `unread_count` 不是 `unread`。差一個字的話這裡永遠讀到
          // 0，紅點永遠不亮——**而畫面看起來完全正常，就是「沒有未讀」**
          unread: (res.data?['unread_count'] as int?) ?? 0,
        );
      });

  /// 標記已讀。[noticeIds] 空的要配 `all: true`，否則 Hub 回 400。
  ///
  /// ⚠️ **兩個參數的位置不一樣，這是實測出來的**（8788 @ `982abe0`）：
  ///
  /// ```
  /// all_notices   query    POST .../read?all_notices=true
  /// notice_ids    body     POST .../read   ["id1","id2"]   ← 裸陣列，不是物件
  /// ```
  ///
  /// FastAPI 對 POST 上沒有 `Query()` 標註的 `list[str]` 當成 **body**，
  /// 而原始型別（`bool`）才是 query。同一個端點上兩種待遇。
  ///
  /// 🔴 我一度把兩個都改成 query——因為早上剛被 `import_members` 教過
  /// 「這種參數走 query」。**那是把一次教訓套得太寬**：結果 notice_ids
  /// 永遠送不到，Hub 回 400 `nothing_to_mark`。這次至少會報錯，
  /// 但錯誤訊息說的是「你沒給 ids」，而我明明給了。
  ///
  /// 沒有這個動作的話，那顆紅點會永遠亮著——**而永遠亮著的紅點，
  /// 第三天就等於不存在了。**
  Future<int> markRead({
    required String sessionKey,
    List<String> noticeIds = const [],
    bool all = false,
  }) =>
      unwrap(() async {
        final res = await _dio.post<Map<String, dynamic>>(
          '/api/board/notices/read',
          data: noticeIds.isEmpty ? null : noticeIds,
          queryParameters: {if (all) 'all_notices': true},
          // ⚠️ **明寫 contentType。** body 是一個裸的 JSON 陣列，不是物件；
          // 不明寫的話 dio 不會替它挑 application/json，Hub 那端就解不出
          // 這個 list，回 422「請求內容不合法」——而 curl 打同一個 payload
          // 是通的，所以很容易誤判成 Hub 的問題
          options: _h(sessionKey)
              .copyWith(contentType: Headers.jsonContentType),
        );
        // 回傳實際標了幾筆。**要用它**——送出去卻標了 0 筆，
        // 與「本來就沒有未讀」在畫面上長得一模一樣
        return (res.data?['marked'] as int?) ?? 0;
      });
}
