import 'package:dio/dio.dart';

import '../models/scratchpad.dart';
import 'api_client.dart';

/// 「這次不要動段落狀態」的哨兵值。
///
/// 🔴 **不能用 `null` 表示這件事**——`null` 在那支 API 上是一個合法值
/// （清除標記）。Hub 判的是欄位在不在 body 裡（`model_fields_set`），
/// 兩者共用同一個表示法的話，「清除」這個動作就寫不出來了。
const Object noStateChange = Object();

/// 「這次不要動段落標籤」的哨兵值。同 [noStateChange] 的理由。
///
/// 🔴 **不送 ≠ 送空陣列。** containsKey 只在**真的不送**時才是「不動」；
/// 送 `[]` 仍然是一個明確的清除。所以這一欄不能回到「optional 帶預設
/// `const []`」——那個寫法會讓「忘了帶」等於清空標籤，而它 09/06 才在
/// bridge 那一側真的丟過資料（卡 `c22ca1b4`）。
const Object noTagsChange = Object();

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
    List<String> tags = const [],
  }) =>
      unwrap(() async {
        final res = await _dio.post<Map<String, dynamic>>(
          '/api/boards/$boardId/scratchpads/$padId/blocks',
          data: {
            'content': content,
            'after_block_id': afterBlockId,
            'tags': tags,
          },
          options: _h(sessionKey),
        );
        return (res.data?['id'] as String?) ?? '';
      });

  /// 改一個段落。
  ///
  /// ⚠️ [rev] **必填、沒有預設值**。給了預設值等於「不知道就當作沒人改過」，
  /// 而那正是 CAS 要擋的那件事。改不動時 Hub 回 409 `scratchpad_block_stale`
  /// 並附上**現值的 content 與 rev**——那兩個是衝突畫面唯一的材料。
  ///
  /// [tags] 與 [state] 都走**哨兵**：不傳＝不動、傳值＝設定、傳空＝清除。
  /// 見 [noTagsChange] / [noStateChange]——`null` 與 `[]` 在這支 API 上都是
  /// **合法值**（清除），所以「沒給」需要另一個表示法。
  ///
  /// 🔴 **不要為了「方便」給它們預設值。** 預設 `const []` 會讓「忘了帶」
  /// 變成一次靜默的清除，而那正是 `c22ca1b4` 的形狀：bridge 的
  /// `chatroom_scratchpad_edit` 只送 content 與 rev，於是 agent 每一次改寫
  /// 段落都把標籤清成空——200 回來、兩邊都沒有錯誤訊息。
  Future<int> writeBlock(
    String boardId,
    String padId,
    String blockId, {
    required String sessionKey,
    required String content,
    required int rev,
    Object? tags = noTagsChange,
    Object? state = noStateChange,
  }) =>
      unwrap(() async {
        final res = await _dio.put<Map<String, dynamic>>(
          '/api/boards/$boardId/scratchpads/$padId/blocks/$blockId',
          // Hub 判的是 `model_fields_set`——**欄位不在 body 裡就是「不動」**。
          // 所以這裡是真的不放那個 key，不是放一個代表「不動」的值：後者在
          // 那個判準下等於「設定成這個值」，而對 tags 來說那個值是清空。
          //
          // 📌 兩欄的降級方向不同，但寫法一樣：`state` 是新欄位（舊 Hub 沒
          // 有它，送不送都不影響），`tags` 在舊 Hub 上是整份覆寫（不送＝
          // 清除）。**這個寫法只在確認沒有舊 Hub 之後才安全**——艾斯維爾
          // 09/06 確認不會再起舊版，卡 `dfb98c7b` 才動的
          data: {
            'content': content,
            'rev': rev,
            if (!identical(tags, noTagsChange)) 'tags': tags ?? const <String>[],
            if (!identical(state, noStateChange)) 'state': state ?? '',
          },
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

/// 卡片追蹤。
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
}
