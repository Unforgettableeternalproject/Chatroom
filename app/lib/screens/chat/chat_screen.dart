import 'dart:async';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:pasteboard/pasteboard.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/errors/api_exception.dart';
import '../../core/theme/uep_theme.dart';
import '../../core/theme/uep_tokens.dart';
import '../../core/util/image_bytes.dart';
import '../../core/util/member_nesting.dart';
import '../../core/util/relative_time.dart';
import '../../models/message.dart';
import '../../api/attachments_api.dart';
import '../../api/messages_api.dart';
import '../../api/rooms_api.dart';
import '../../models/participant.dart';
import '../../models/room_style.dart';
import '../../state/app_providers.dart';
import '../../notifications/taskbar_badge.dart';
import '../../state/messages_providers.dart';
import '../../state/notification_providers.dart';
import '../../state/highlighted_members_provider.dart';
import '../../state/rooms_providers.dart';
import '../../widgets/archive_request_banner.dart';
import '../../widgets/composer_attachments.dart';
import '../../widgets/export_room_button.dart';
import '../../widgets/invite_human_dialog.dart';
import '../../widgets/delete_room_confirm.dart';
import '../../widgets/room_style_picker.dart';
import '../../widgets/empty_error_states.dart';
import '../../widgets/kind_badge.dart';
import '../../widgets/mention_field.dart';
import '../../widgets/message_bubble.dart';
import '../../widgets/question_card.dart';
import '../../widgets/system_message_tile.dart';
import '../../widgets/uep_button.dart';
import '../../ws/realtime_service.dart';

class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({super.key, required this.roomId, this.focusSeq});

  final String roomId;
  final int? focusSeq;

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final _scroll = ScrollController();
  Timer? _heartbeat;
  Message? _replyTarget;

  /// 正在編輯的訊息。與 [_replyTarget] 互斥——設定其中一個就清掉另一個，
  /// 否則送出時分不出該發新訊息還是改舊的。
  Message? _editTarget;
  int _newWhileAway = 0;
  int _lastSeenCount = 0;
  int? _lastSystemCount;
  int? _highlightSeq;

  /// 掛在目前跳轉目標那一則上，讓 `_focusOn` 的第二段量得到它的實際位置。
  /// 同一時間只有一則訊息會命中 `_highlightSeq`，所以這把 GlobalKey 不會
  /// 同時出現在兩個 widget 上。
  final GlobalKey _focusKey = GlobalKey();
  Timer? _highlightTimer;
  bool _loadingOlder = false;
  Timer? _memberPoll;
  DateTime? _lastMemberFetch;

  /// 已經為了「這個陌生發送者」重抓過成員列的 id。
  ///
  /// 保險，不是最佳化：目前房間詳情會回**所有狀態**的成員（含已離開的
  /// 子代理），所以重抓一次之後那個 id 就認得了。但這件事是端點的行為，
  /// 不是這個畫面控制得了的——哪天它改成只回 active，這裡就會變成
  /// 「重抓 → 還是不認得 → 再重抓」的無限迴圈，而症狀是 App 對著 Hub
  /// 狂打請求，沒有任何錯誤訊息（測試端 2026-08-31 指出這個交互作用）。
  /// 記下來就永遠只會為同一個 id 打一次。
  final Set<String> _refetchedFor = {};

  /// 待送附件。先上傳、送出時才把 id 帶進訊息——見 ComposerAttachment 的說明。
  final List<ComposerAttachment> _pending = [];

  /// 拖放游標是否停在視窗上（畫提示用）。
  bool _dragging = false;
  int _localSeq = 0;

  bool get _atBottom => !_scroll.hasClients || _scroll.position.pixels < 60;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    // 標記名單從本機設定讀進來一次。放在這裡而不是 build：Notifier 在
    // build 期間改 state 會炸，而它本來就只需要讀一次
    ref.read(highlightedMembersProvider.notifier).ensureLoaded(widget.roomId);
    _startHeartbeat();
    _startMemberPoll();
    // 通知抑制的 activeRoomId 由 router 推導（見 app.dart _syncActiveRoom）——
    // 綁在這裡的話，被 push 蓋住而沒 dispose 時會繼續抑制通知
    if (widget.focusSeq != null) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _focusOn(widget.focusSeq!),
      );
    }
  }

  @override
  void didUpdateWidget(covariant ChatScreen old) {
    super.didUpdateWidget(old);
    if (old.roomId != widget.roomId) {
      _replyTarget = null;
      _newWhileAway = 0;
      _lastSeenCount = 0;
      _lastSystemCount = null;
      _startHeartbeat();
      _startMemberPoll();
    }
    if (widget.focusSeq != null && widget.focusSeq != old.focusSeq) {
      _focusOn(widget.focusSeq!);
    }
  }

  @override
  void dispose() {
    _heartbeat?.cancel();
    _highlightTimer?.cancel();
    _memberPoll?.cancel();
    // 離開畫面時把還在傳的取消掉，否則它會傳完後往一個已 dispose 的 State
    // 寫結果；已傳完的就留在 Hub 上（無主附件，不影響任何人）
    for (final a in _pending) {
      if (a.status == ComposerAttachmentStatus.uploading) {
        a.cancelToken?.cancel('離開聊天室');
      }
    }
    _scroll.dispose();
    super.dispose();
  }

  // ---------- 成員列的定期重抓 ----------

  /// 成員列原本只在「系統訊息數量變了」時重抓（見底下的 ref.listen）。
  ///
  /// **subagent 的進出不進訊息流**（設計如此，見 docs/SUBAGENT-IDENTITY.md
  /// §2），所以那個觸發器對它們完全不作用：子代理加入時列表不會長出來、
  /// 結束時也不會消失，要離房重進才對。實際看到的是後者——一個已經結束的
  /// 子代理**繼續掛在成員列上**，那正是這份設計要消滅的殭屍成員形狀，
  /// 只是從人類這一側現形（艾斯維爾 2026-08-31 實機發現）。
  ///
  /// 這是「不進訊息流」這個決定的直接代價，不是 App 少寫了什麼——訊息流
  /// 本來就是成員列唯一的更新訊號，抽掉它就要另外給一個。
  ///
  /// 20 秒是刻意的：它要明顯短於 subagent 的 TTL（`CHATROOM_SUBAGENT_TIMEOUT`，
  /// 預設 900 秒），「已經被回收的成員」才不會在畫面上留超過一個輪詢週期。
  /// 這裡不重述那個秒數——它改過一次（120 → 900），而散文裡的複本不會跟著改。
  void _startMemberPoll() {
    _memberPoll?.cancel();
    _memberPoll = Timer.periodic(const Duration(seconds: 20), (_) {
      if (!mounted) return;
      ref.invalidate(roomDetailProvider(widget.roomId));
    });
  }

  // ---------- heartbeat（讓其他 agent 看到人類在線；60s 一次即可） ----------

  void _startHeartbeat() {
    _heartbeat?.cancel();
    _heartbeat = Timer.periodic(const Duration(seconds: 60), (_) async {
      final identity = ref.read(identityProvider(widget.roomId)).value;
      if (identity == null) return;
      try {
        await ref
            .read(roomsApiProvider)
            .heartbeat(widget.roomId, participantId: identity.participantId);
      } on ParticipantInvalidException {
        // 身分失效（離房 / DB 重置）→ 重新 join（§6.4）
        ref.invalidate(identityProvider(widget.roomId));
      } on ApiException {
        // 網路層問題由 realtime 狀態機處理，這裡靜默
      }
    });
  }

  // ---------- 捲動 ----------

  void _onScroll() {
    if (_atBottom && _newWhileAway != 0) {
      setState(() => _newWhileAway = 0);
    }
    // reverse list：接近 maxScrollExtent = 視窗頂端 → 載入更舊的歷史
    if (!_loadingOlder &&
        _scroll.hasClients &&
        _scroll.position.pixels > _scroll.position.maxScrollExtent - 400) {
      _loadOlder();
    }
  }

  Future<void> _loadOlder() async {
    final feed = ref.read(roomFeedProvider(widget.roomId));
    if (!feed.hasMoreHistory) return;
    _loadingOlder = true;
    try {
      await ref.read(realtimeServiceProvider).loadOlder(widget.roomId);
    } finally {
      _loadingOlder = false;
    }
  }

  /// 已經在退場了。ref.listen 會從兩個 provider 各觸發一次，沒有這個旗標
  /// 就會導航兩次、也會跳兩則 snackbar。
  bool _leaving = false;

  /// 拿不到身分**且**讀不到房間 → 這個房對我而言不存在，退場回列表。
  ///
  /// 走的是與「被管理員移出」完全一樣的收尾（清本機身分、退訂、回列表），
  /// 因為對使用者來說結果是同一件事：這個房他進不去了。留在原地只會看到
  /// 一個永遠在重連的空畫面。
  void _leaveIfUnreadable(WidgetRef ref) {
    if (_leaving) return;
    final identity = ref.read(identityProvider(widget.roomId));
    final detail = ref.read(roomDetailProvider(widget.roomId));
    // hasError 而不是 !hasValue：loading 中兩者都還沒有值，那是正常過程
    if (!identity.hasError || !detail.hasError) return;
    _leaving = true;
    unawaited(() async {
      final settings = ref.read(settingsRepoProvider);
      await settings.setParticipantId(widget.roomId, null);
      ref.read(realtimeServiceProvider).unsubscribe(widget.roomId);
      if (!mounted) return;
      context.go('/rooms');
      // 刻意**不轉述 Hub 的原話**。走到這裡的錯誤多半是 401
      // `participant_header_required`，而那句話（「這個畫面沒有帶上房間
      // 身分（程式問題，與 API token 無關）」）是寫給改程式的人看的——
      // 它在別的地方是對的，因為那裡確實是呼叫端漏帶標頭。這裡不是：
      // 使用者做的事是「點了一個他沒份的房」，那句話對他毫無意義。
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('你不是這個聊天室的成員，看不到房內的內容'),
      ));
    }());
  }

  void _scrollToBottom() {
    // 送出成功時也會走這裡，而那條路徑不保證 list 已經 attach（剛進房就
    // 發言、或畫面正在重建）。沒有 clients 時安靜跳過捲動即可——reverse
    // list 的初始位置本來就是底部，不捲也在對的地方
    if (_scroll.hasClients) {
      _scroll.animateTo(
        0,
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOut,
      );
    }
    setState(() => _newWhileAway = 0);
  }

  /// 那一則還在不在？用錨定讀取問 Hub 一次，不動 feed。
  ///
  /// **只用來判斷，不把結果灌進 store**：`around_seq` 回的是「錨點前後」，
  /// 而 feed 是單一連續視窗——灌進去會在中間留一段沒載入的洞，畫面上卻連續
  /// 顯示（既有註解說的「時間軸假連續」）。真正要跳到很舊的訊息得改成錨定
  /// 視窗模式，那是另一張票。
  ///
  /// 拿不到答案時回 `true`（照原本的逐頁流程走）——網路不穩不該讓一個
  /// 存在的訊息被說成不存在。
  Future<bool> _messageStillExists(int seq) async {
    try {
      final identity = await ref.read(identityProvider(widget.roomId).future);
      final page = await ref.read(messagesApiProvider).read(
            widget.roomId,
            aroundSeq: seq,
            radius: 1,
            participantId: identity.participantId,
          );
      return page.messages.any((m) => m.seq == seq);
    } catch (_) {
      return true;
    }
  }

  Future<void> _focusOn(int seq) async {
    var feed = ref.read(roomFeedProvider(widget.roomId));
    // 先問一次「那則還在不在」，再決定要不要往回翻。一次請求換掉最多 30 輪
    // 的白跑，而且**「已經不存在」與「太舊還沒載到」從此分得開**——原本
    // 兩者都是安靜地什麼都不做
    if (feed.bySeq(seq) == null && !await _messageStillExists(seq)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('那則訊息已經不在這個聊天室裡了')),
        );
      }
      return;
    }
    if (!mounted) return;
    // 目標不在視窗內就持續往回載，直到載到或沒有更多歷史
    var guard = 0;
    while (feed.bySeq(seq) == null && feed.hasMoreHistory && guard < 30) {
      await ref.read(realtimeServiceProvider).loadOlder(widget.roomId);
      feed = ref.read(roomFeedProvider(widget.roomId));
      guard++;
    }
    if (!mounted) return;
    if (feed.bySeq(seq) == null) {
      // **跳不到要說出來。** 原本這裡是安靜 return，使用者按了「跳回原文」
      // 卻什麼都沒發生，分不出是當掉了還是訊息不見了
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            feed.hasMoreHistory
                ? '那則訊息太舊了，已載入 ${feed.length} 則仍沒跳到——再往上捲一段後重試'
                : '找不到那則訊息',
          ),
        ),
      );
      return;
    }
    final list = feed.messages.toList();
    final index = list.indexWhere((m) => m.seq == seq);
    if (index < 0) return;

    // 先標記目標，_focusKey 才會掛到那一則上——精修那一步要靠它拿到 context
    setState(() => _highlightSeq = seq);

    // 第一段：以估計高度粗跳。這個估計一定不準（一行字約 60px，帶圖片的
    // 氣泡好幾百），往回兩百則就差出好幾個螢幕；它的任務只是把目標帶進
    // build 範圍，讓第二段有東西可以量
    final fromBottom = list.length - 1 - index;
    const estimatedExtent = 96.0;
    final target = (fromBottom * estimatedExtent).clamp(
      0.0,
      _scroll.hasClients ? _scroll.position.maxScrollExtent : 0.0,
    );
    if (_scroll.hasClients) {
      await _scroll.animateTo(
        target,
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOut,
      );
    }

    // 第二段：目標真的被 build 出來之後，用它自己的高度精修到畫面中央。
    // 兩段是必要的——ensureVisible 對還沒 build 的 item 無效，而粗跳的
    // 誤差正好大到會讓目標落在 viewport 外
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    // 跨了 endOfFrame 這個 async gap，所以要檢查的是**那個 context 自己**
    // 還在不在（State.mounted 不能代答：目標訊息可能已經被捲出 build 範圍）
    final ctx = _focusKey.currentContext;
    if (ctx != null && ctx.mounted) {
      await Scrollable.ensureVisible(
        ctx,
        alignment: 0.5,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    }
    if (!mounted) return;
    _highlightTimer?.cancel();
    _highlightTimer = Timer(const Duration(milliseconds: 1500), () {
      if (mounted) setState(() => _highlightSeq = null);
    });
  }

  // ---------- 附件 ----------

  /// Hub 實際的單檔上限。伺服器沒回時退回預設值——寫死一個數字會讓人在
  /// 上限被調大之後仍然被 App 自己擋下來。
  int get _maxAttachmentBytes =>
      ref
          .read(roomDetailProvider(widget.roomId))
          .value
          ?.limits
          .maxAttachmentBytes ??
      const ServerLimits().maxAttachmentBytes;

  void _replacePending(String localId, ComposerAttachment next) {
    final i = _pending.indexWhere((a) => a.localId == localId);
    if (i < 0) return; // 使用者已經把它移掉了
    setState(() => _pending[i] = next);
  }

  Future<void> _pickFiles() async {
    // file_picker 12 起 pickFiles 是靜態方法，取消時回空 list 而不是 null
    final files = await FilePicker.pickFiles();
    for (final f in files) {
      final path = f.path;
      if (path == null) continue;
      await _enqueue(filename: f.name, size: await f.length(), path: path);
    }
  }

  Future<void> _dropFiles(List<DropItem> items) async {
    for (final item in items) {
      final stat = await FileStat.stat(item.path);
      // 拖進來的可能是資料夾。整包上傳不是這個功能該做的事，靜默跳過又會
      // 讓人以為是壞了，所以講一句
      if (stat.type == FileSystemEntityType.directory) {
        _toast('${item.name} 是資料夾，未加入');
        continue;
      }
      await _enqueue(filename: item.name, size: stat.size, path: item.path);
    }
  }

  /// 從剪貼簿取圖。回傳是否真的取到——沒有圖的話（一般文字貼上）什麼都不做。
  Future<bool> _pasteImage() async {
    final Uint8List? bytes;
    try {
      bytes = await Pasteboard.image;
    } catch (_) {
      // 平台不支援或剪貼簿被別的程式鎖住；貼上失敗不該讓輸入框壞掉
      return false;
    }
    if (bytes == null || bytes.isEmpty) return false;
    // Windows 剪貼簿給的是 BMP，直接當 png 送出去只有 App 自己讀得懂——
    // 見 toPngBytes 的說明
    final png = await toPngBytes(bytes);
    await _enqueue(
      // 剪貼簿的圖沒有檔名，用房內遞增的本機序號區分同一次對話裡的多張
      filename: '貼上的圖片-${++_localSeq}.png',
      size: png.length,
      bytes: png,
      mime: 'image/png',
    );
    return true;
  }

  Future<void> _enqueue({
    required String filename,
    required int size,
    String? path,
    Uint8List? bytes,
    String? mime,
  }) async {
    if (size > _maxAttachmentBytes) {
      // 先擋在本機：明知會被拒絕還是把整個檔案推上去，只是白白佔用頻寬與時間
      final mb = (_maxAttachmentBytes / (1024 * 1024)).toStringAsFixed(0);
      _toast('$filename 超過上限 $mb MB，未加入');
      return;
    }
    // Hub 的 attachment_ids 上限是 10，超過會整則訊息被擋下來
    if (_pending.length >= 10) {
      _toast('一則訊息最多 10 個附件');
      return;
    }
    final item = ComposerAttachment(
      localId: '${DateTime.now().microsecondsSinceEpoch}-${_pending.length}',
      filename: filename,
      mime: mime ?? _guessMime(filename),
      size: size,
      path: path,
      bytes: bytes,
      cancelToken: CancelToken(),
    );
    setState(() => _pending.add(item));
    await _upload(item);
  }

  Future<void> _upload(ComposerAttachment item) async {
    final api = ref.read(attachmentsApiProvider);
    try {
      final identity = await ref.read(identityProvider(widget.roomId).future);
      void onProgress(int sent, int total) {
        if (!mounted || total <= 0) return;
        _replacePending(item.localId, item.copyWith(progress: sent / total));
      }

      final uploaded = item.bytes != null
          ? await api.uploadBytes(
              widget.roomId,
              participantId: identity.participantId,
              bytes: item.bytes!,
              filename: item.filename,
              mime: item.mime,
              onProgress: onProgress,
              cancelToken: item.cancelToken,
            )
          : await api.uploadPath(
              widget.roomId,
              participantId: identity.participantId,
              path: item.path!,
              filename: item.filename,
              mime: item.mime,
              onProgress: onProgress,
              cancelToken: item.cancelToken,
            );
      if (!mounted) return;
      _replacePending(
        item.localId,
        item.copyWith(
          status: ComposerAttachmentStatus.ready,
          progress: 1,
          remoteId: uploaded.id,
        ),
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      _replacePending(
        item.localId,
        item.copyWith(
          status: ComposerAttachmentStatus.failed,
          error: e.message,
        ),
      );
    } on DioException catch (e) {
      if (!mounted) return;
      // 取消是使用者自己按的，不是錯誤——那個項目已經被移掉了
      if (CancelToken.isCancel(e)) return;
      _replacePending(
        item.localId,
        item.copyWith(status: ComposerAttachmentStatus.failed, error: '上傳失敗'),
      );
    }
  }

  void _removePending(ComposerAttachment a) {
    if (a.status == ComposerAttachmentStatus.uploading) {
      a.cancelToken?.cancel('使用者取消');
    }
    setState(() => _pending.removeWhere((x) => x.localId == a.localId));
  }

  Future<void> _retryPending(ComposerAttachment a) async {
    final fresh = a.copyWith(
      status: ComposerAttachmentStatus.uploading,
      progress: 0,
      cancelToken: CancelToken(),
    );
    _replacePending(a.localId, fresh);
    await _upload(fresh);
  }

  static String _guessMime(String filename) {
    final ext = filename.contains('.')
        ? filename.split('.').last.toLowerCase()
        : '';
    return switch (ext) {
      'png' => 'image/png',
      'jpg' || 'jpeg' => 'image/jpeg',
      'gif' => 'image/gif',
      'webp' => 'image/webp',
      'bmp' => 'image/bmp',
      'svg' => 'image/svg+xml',
      'pdf' => 'application/pdf',
      'txt' || 'log' || 'md' => 'text/plain',
      'json' => 'application/json',
      'zip' => 'application/zip',
      _ => 'application/octet-stream',
    };
  }

  /// 群組 @ 展開成空的話講出來——例如房裡沒有人類卻發了 `@humans`。
  ///
  /// 不講的話，送出後的畫面與「成功叫到一群人」完全一樣，而發話者會就這樣
  /// 等下去。與 `unresolved_mentions`（打錯的人名）同族：**你以為叫到人了，
  /// 其實沒有**。
  void _warnEmptyGroups(PostResult sent) {
    if (sent.emptyGroups.isEmpty) return;
    final names = sent.emptyGroups.map((g) => '@$g').join('、');
    _toast('$names 現在房裡沒有對應的人，沒有人被叫醒');
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  // ---------- 動作 ----------

  /// 送出一次編輯。
  ///
  /// 內容沒變就當作取消——送一次 PATCH 只會給那則掛上「已編輯」標記，
  /// 而使用者什麼都沒改。
  Future<void> _submitEdit(Message target, String content) async {
    if (content.trim() == target.content.trim()) {
      setState(() => _editTarget = null);
      return;
    }
    final identity = await ref.read(identityProvider(widget.roomId).future);
    try {
      await ref.read(messagesApiProvider).edit(
            target.id,
            participantId: identity.participantId,
            content: content,
          );
      if (mounted) setState(() => _editTarget = null);
    } on ApiException catch (e) {
      // 訊息照 Hub 的講法：常見情境是這則剛被別人刪掉，或房間剛被封存
      _toast(e.message);
    }
  }

  Future<void> _send(String content, List<String> mentions) async {
    // 編輯中就走編輯，不發新訊息。分岔放在這裡而不是輸入列裡：輸入列是純
    // 呈現元件，不該知道 Hub 的存在
    final editing = _editTarget;
    if (editing != null) {
      await _submitEdit(editing, content);
      return;
    }
    final identity = await ref.read(identityProvider(widget.roomId).future);
    // 只帶已上傳完成的；輸入列不讓有未完成項目時送出，這裡是第二道防線
    final attachmentIds = [
      for (final a in _pending)
        if (a.isReady && a.remoteId != null) a.remoteId!,
    ];
    try {
      final sent = await ref
          .read(messagesApiProvider)
          .post(
            widget.roomId,
            participantId: identity.participantId,
            content: content,
            mentions: mentions,
            replyTo: _replyTarget?.id,
            attachmentIds: attachmentIds,
          );
      _warnEmptyGroups(sent);
      if (mounted) {
        setState(() {
          _replyTarget = null;
          _pending.clear();
        });
        // 自己按下送出是明確的意圖表達：「我剛說的話在哪」比「保持原本的
        // 閱讀位置」重要。所以**無條件**回到底部，不看 _atBottom——
        // 往上翻歷史時發言卻看不到自己的訊息，正是「沒有自動捲動」的症狀
        _scrollToBottom();
      }
    } on ParticipantInvalidException {
      // 身分失效：重新 join 後重試一次（僅一次，避免無限迴圈）
      ref.invalidate(identityProvider(widget.roomId));
      final fresh = await ref.read(identityProvider(widget.roomId).future);
      await ref
          .read(messagesApiProvider)
          .post(
            widget.roomId,
            participantId: fresh.participantId,
            content: content,
            mentions: mentions,
            replyTo: _replyTarget?.id,
            attachmentIds: attachmentIds,
          );
      if (mounted) {
        setState(() {
          _replyTarget = null;
          _pending.clear();
        });
        // 自己按下送出是明確的意圖表達：「我剛說的話在哪」比「保持原本的
        // 閱讀位置」重要。所以**無條件**回到底部，不看 _atBottom——
        // 往上翻歷史時發言卻看不到自己的訊息，正是「沒有自動捲動」的症狀
        _scrollToBottom();
      }
    } on ApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
      }
      rethrow;
    }
  }

  Future<void> _togglePin(Message m) async {
    try {
      final identity = await ref.read(identityProvider(widget.roomId).future);
      final api = ref.read(messagesApiProvider);
      if (m.pinned) {
        await api.unpin(m.id, participantId: identity.participantId);
      } else {
        await api.pin(m.id, participantId: identity.participantId);
      }
    } on ApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
      }
    }
  }

  Future<void> _delete(Message m) async {
    final s = context.uep;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          '刪除這則訊息？',
          style: UepText.display(size: 24, color: s.inkTitle),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              decoration: BoxDecoration(
                border: Border(
                  left: BorderSide(color: s.hairlineStrong, width: 2),
                ),
              ),
              padding: const EdgeInsets.only(left: 12),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '${m.senderName ?? '（未知）'} · ${clockTime(m.createdAt)}　'
                  '${m.content.length > 60 ? '${m.content.substring(0, 60)}…' : m.content}',
                  style: UepText.serif(size: 13, color: s.inkMute, height: 1.8),
                ),
              ),
            ),
            const SizedBox(height: 14),
            Text(
              '訊息會留下「訊息已刪除」的占位，不會從時間軸消失。此操作無法復原。',
              style: UepText.serif(size: 13.5, color: s.inkSoft),
            ),
          ],
        ),
        actions: [
          UepButton(
            label: '取消',
            variant: UepButtonVariant.outline,
            small: true,
            onPressed: () => Navigator.of(context).pop(false),
          ),
          UepButton(
            label: '刪除',
            variant: UepButtonVariant.danger,
            small: true,
            onPressed: () => Navigator.of(context).pop(true),
          ),
        ],
      ),
    );
    if (confirmed ?? false) {
      try {
        final identity = await ref.read(identityProvider(widget.roomId).future);
        await ref
            .read(messagesApiProvider)
            .delete(m.id, participantId: identity.participantId);
      } on ApiException catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(e.message)));
        }
      }
    }
  }

  // ---------- build ----------

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    final roomId = widget.roomId;
    final detailAsync = ref.watch(roomDetailProvider(roomId));
    // 附件要直接向 Hub 取圖，因此氣泡需要位址與 token
    final config = ref.watch(appConfigProvider);
    final messagesAsync = ref.watch(messagesProvider(roomId));
    final feed = ref.watch(roomFeedProvider(roomId));
    // 讓 join 在進房時就發生（不等第一次發言）
    final identityAsync = ref.watch(identityProvider(roomId));

    // 重連補訊完成後刷新成員與房間狀態（§4.4 步驟 [4]）
    ref.listen(connectionStatusProvider, (prev, next) {
      if (next.value is Connected && prev?.value is! Connected) {
        ref.invalidate(roomDetailProvider(roomId));
      }
    });

    // 自己的 join 完成後刷新成員：新房間常在 join 完成前就抓了 detail，
    // 成員清單會缺自己（kind 徽章全落 other、@ 選單空白）
    ref.listen(identityProvider(roomId), (prev, next) {
      if (next.hasValue && prev?.hasValue != true) {
        ref.invalidate(roomDetailProvider(roomId));
        // 進房會讓 Hub 把對應的指派標成 accepted——邀請卡該在**這一刻**消失，
        // 而不是等房間列表下一輪輪詢。走 `/rooms/...` 進來的人是從那張卡點
        // 過來的，回列表時還看到它等於「按了沒反應」
        ref.invalidate(roomListProvider);
      }
    });

    // 讀不到這個房 → 退場回列表，與「被管理員移出」同一條路。
    //
    // 🚨 **判定必須是「拿不到身分 *且* 讀不到房間」**，不能只看其中一個：
    // - 只看讀取失敗：join 還在跑的時候讀取本來就會 401
    //   （`participant_header_required` 是「還不知道你是誰」，不是
    //   「你不是成員」），那是時序，不是權限
    // - 只看 join 失敗：封存房本來就 join 不了（409），但成員仍讀得到
    //   歷史——那是刻意保留的唯讀瀏覽，不可以把人踢出去
    //
    // 兩個同時失敗才是真的沒份。實際長出這個需求的情境：主持人用主持人
    // 模式封了一個自己沒份的房，然後把模式關掉——房沒有建立者、他不是
    // 成員，於是畫面停在一個永遠讀不到的房上，只顯示「重連中」。
    ref.listen(identityProvider(roomId), (_, _) => _leaveIfUnreadable(ref));
    ref.listen(roomDetailProvider(roomId), (_, _) => _leaveIfUnreadable(ref));

    // 解封後重建人類身分：封存期間進房的 join 會收到 409，
    // 這個錯誤被 keepAlive 快取住，不清掉會讓之後所有發言都撞「已封存」
    ref.listen(roomDetailProvider(roomId), (prev, next) {
      final wasArchived = prev?.value?.room.isArchived ?? false;
      final detail = next.value;
      if (wasArchived && detail != null && !detail.room.isArchived) {
        ref.invalidate(identityProvider(roomId));
      }
    });

    // 新訊息計數（使用者不在底部時不強制捲動，顯示提示 pill）
    ref.listen(messagesProvider(roomId), (prev, next) {
      final list = next.value;
      if (list == null) return;
      final chatCount = list.where((m) => !m.isSystem).length;
      if (_lastSeenCount != 0 && chatCount > _lastSeenCount && !_atBottom) {
        setState(() => _newWhileAway += chatCount - _lastSeenCount);
      }
      _lastSeenCount = chatCount;
      // 系統訊息（加入/離開/封存/解封）到達 → 成員與房間狀態已變，刷新 detail
      final systemCount = list.where((m) => m.isSystem).length;
      if (_lastSystemCount != null && systemCount != _lastSystemCount) {
        ref.invalidate(roomDetailProvider(roomId));
      }
      _lastSystemCount = systemCount;
      // **房裡有任何動靜就重抓成員列**，不只看系統訊息。
      //
      // 系統訊息本來是成員變動的唯一訊號，但 subagent 的進出刻意不進訊息流
      // （docs/SUBAGENT-IDENTITY.md §2），那個訊號對它們完全不作用——結果是
      // 已經結束的子代理繼續掛在列表上，而剛加入的那個頂著「other」徽章
      // （艾斯維爾 2026-08-31 實機發現）。抽掉唯一的更新訊號，就要另外給。
      //
      // 節流 3 秒：一則訊息一次重抓在熱絡的房裡是白費的請求，而成員變動
      // 慢得多。陌生發送者不受節流限制——那是「有人在說話而我不認識他」，
      // 等三秒等於讓他的第一則發言頂著錯的徽章。
      final known = detailAsync.value?.participants;
      final ids = {
        for (final p in known ?? const <Participant>[]) ...{p.id, ...p.aliasIds},
      };
      final unknown = ids.isEmpty
          ? const <String>[]
          : [
              for (final m in list)
                if (m.senderId != null &&
                    !ids.contains(m.senderId) &&
                    !_refetchedFor.contains(m.senderId))
                  m.senderId!,
            ];
      final stranger = unknown.isNotEmpty;
      _refetchedFor.addAll(unknown);
      final now = DateTime.now();
      final due = _lastMemberFetch == null ||
          now.difference(_lastMemberFetch!) > const Duration(seconds: 3);
      if (stranger || due) {
        _lastMemberFetch = now;
        ref.invalidate(roomDetailProvider(roomId));
      }
      // 已讀 cursor：視窗開著就推進（未讀點的資料源）
      final settings = ref.read(settingsRepoProvider);
      settings.setLastReadSeq(roomId, feed.cursor);
      // 人真的在看這個房了，那些 @ 就算處理過。**只清 mention，不清問題**
      // ——問題要答了才算完，看到不算（那正是「容易被忽略」的成因）
      if (settings.pendingMentions(roomId) > 0) {
        settings.clearPendingMentions(roomId).then((_) {
          TaskbarBadge.instance.apply(
            unhandledCount(
              realtime: ref.read(realtimeServiceProvider),
              pendingInvites: ref.read(myPendingInvitesProvider).length,
              settings: settings,
            ),
          );
        });
      }
    });

    final archived =
        feed.roomStatus == 'archived' ||
        (detailAsync.value?.room.isArchived ?? false);
    final members = detailAsync.value?.participants ?? const [];
    final activeMembers = members
        .where((p) => p.isActive)
        .toList(growable: false);
    final myId = identityAsync.value?.participantId;
    final room = detailAsync.value?.room;
    final zone = zoneForRoomId(roomId);
    final palette = uepZonePalettes[zone]!;

    final pinnedMessages = feed.messages
        .where((m) => m.pinned && !m.deleted)
        .toList(growable: false);

    final actions = MessageActions(
      onReply: (m) => setState(() {
        _replyTarget = m;
        _editTarget = null;
      }),
      onEdit: (m) => setState(() {
        _editTarget = m;
        _replyTarget = null;
      }),
      onTogglePin: _togglePin,
      onDelete: _delete,
      enabled: !archived,
    );

    // 被我標記的成員：時間軸與側欄共用同一份，所以放在 provider 裡
    // （載入在 initState，build 期間不改 state）
    final highlightedIds =
        ref.watch(highlightedMembersProvider)[roomId] ?? const <String>{};
    final kindById = {
      for (final p in members) ...{
        p.id: p.kind,
        // 同 session 的舊身分（換名重進前）沿用同一 kind
        for (final alias in p.aliasIds) alias: p.kind,
      },
    };
    // 子代理的發話者 → 父層名字。歷史訊息也要對得回去，所以掃的是
    // `members`（含已離開的）而不是 activeMembers——子代理本來就是短命的，
    // 只認 active 的話它一走，它說過的話就變成無主的發言
    // aliases 也要收：父層離開後重進會拿到新的 participant id，舊 id 被
    // Hub 收進 alias_ids，而歷史 subagent 的 parent_id 指的是**舊的那個**。
    // 只收代表列的話，那些訊息會顯示「（未知）的子代理」——看起來像資料
    // 壞了，其實只是對照表少了一半（Codex review #6）
    final nameById = {
      for (final p in members) ...{
        p.id: p.displayName,
        for (final alias in p.aliasIds) alias: p.displayName,
      },
    };
    final subagentParentById = {
      for (final p in members)
        if (p.ephemeral && p.parentId != null)
          p.id: nameById[p.parentId!] ?? '（未知）',
    };

    final wide = MediaQuery.sizeOf(context).width >= 1200;

    final chatColumn = _withDropTarget(
      s,
      Column(
        children: [
          _RoomHeader(
            roomId: roomId,
            roomName: room?.name ?? '…',
            topic: room?.topic ?? '',
            archived: archived,
            zoneLabel: zone.name.toUpperCase(),
            zoneColor: palette.soft,
            zoneStroke: palette.stroke(Theme.of(context).brightness),
            pinnedCount: pinnedMessages.length,
            memberCount: activeMembers.length,
            showMembersButton: !wide,
          ),
          if (pinnedMessages.isNotEmpty && !archived)
            _PinnedStrip(roomId: roomId, latest: pinnedMessages.last),
          // 封存請求。封存房裡不會有 pending（封存時一律標 superseded），
          // 所以不必自己判斷 archived
          if (detailAsync.value?.archiveRequest case final req?)
            ArchiveRequestBanner(
              roomId: roomId,
              request: req,
              youAreAdmin: detailAsync.value?.youAreAdmin ?? false,
            ),
          Expanded(
            child: Stack(
              children: [
                messagesAsync.when(
                  loading: () => const Center(
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: UepColors.gold,
                      ),
                    ),
                  ),
                  error: (e, _) => ErrorState(
                    error: e,
                    onRetry: () => ref.invalidate(messagesProvider(roomId)),
                  ),
                  data: (messages) {
                    if (messages.isEmpty) {
                      return const EmptyState(
                        title: '還沒有任何訊息',
                        subtitle: '發一則訊息，或指派 agent 加入這個房間',
                      );
                    }
                    // SelectionArea 取代各訊息自己的 SelectableText：右鍵留給訊息
                    // 選單，而選取可以跨訊息（要複製一整段對話時差很多）
                    final list = _desaturateIfArchived(
                      archived,
                      SelectionArea(
                        // **壓掉原生的選取選單。** 上面那句「右鍵留給訊息選單」
                        // 原本只是意圖——SelectionArea 在桌面端自帶一份
                        // context menu（Select all／Copy），於是右鍵會同時彈出
                        // 兩個浮層互相疊壓。
                        //
                        // 回空而不是拿掉 SelectionArea：**拖選的能力要留著**，
                        // 要砍的只有那個選單。複製整則的入口在我們自己的選單裡
                        // （「複製內容」），拖選部分文字則靠這個 SelectionArea。
                        contextMenuBuilder: (_, _) => const SizedBox.shrink(),
                        child: ListView.builder(
                          controller: _scroll,
                          reverse: true,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 24,
                            vertical: 18,
                          ),
                          itemCount:
                              messages.length + (feed.hasMoreHistory ? 1 : 0),
                          itemBuilder: (context, i) {
                            if (i >= messages.length) {
                              return Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 16,
                                ),
                                child: Center(
                                  child: MonoLabel('載入更早的訊息…', size: 9),
                                ),
                              );
                            }
                            final m = messages[messages.length - 1 - i];
                            // 跳轉目標掛上 _focusKey。system 訊息也可能是
                            // 目標（釘選收據就是 system），只掛 chat 分支
                            // 會讓那些跳轉安靜地退回粗跳的誤差
                            Widget keyed(Widget tile) => m.seq == _highlightSeq
                                ? KeyedSubtree(key: _focusKey, child: tile)
                                : tile;
                            if (m.isSystem) {
                              return keyed(SystemMessageTile(message: m));
                            }
                            final kind = m.senderId != null
                                ? (kindById[m.senderId] ?? 'other')
                                : 'other';
                            return keyed(Padding(
                              padding: const EdgeInsets.symmetric(vertical: 9),
                              child: MessageBubble(
                                message: m,
                                isSelf: myId != null && m.senderId == myId,
                                senderKind: kind,
                                actions: actions,
                                highlighted: _highlightSeq == m.seq,
                                memberHighlighted: m.senderId != null &&
                                    highlightedIds.contains(m.senderId),
                                serverUrl: config.serverUrl,
                                token: config.token,
                                // 附件下載也在讀取邊界內（Hub 側 3605638）
                                participantId: myId,
                                subagentOf: m.senderId == null
                                    ? null
                                    : subagentParentById[m.senderId],
                              ),
                            ));
                          },
                        ),
                      ),
                    );
                    return list;
                  },
                ),
                if (_newWhileAway > 0)
                  Positioned(
                    bottom: 16,
                    left: 0,
                    right: 0,
                    child: Center(
                      child: InkWell(
                        borderRadius: BorderRadius.circular(999),
                        onTap: _scrollToBottom,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: s.bgCard,
                            borderRadius: BorderRadius.circular(999),
                            border: Border.all(
                              color: UepColors.gold.withValues(alpha: .35),
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: .45),
                                blurRadius: 30,
                                offset: const Offset(0, 12),
                              ),
                            ],
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                '有 $_newWhileAway 則新訊息',
                                style: UepText.mono(
                                  size: 9.5,
                                  color: UepColors.gold,
                                  letterSpacing: 1.2,
                                ),
                              ),
                              const SizedBox(width: 8),
                              const Text(
                                '↓',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: UepColors.gold,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (myId != null)
            _PendingQuestions(roomId: roomId, participantId: myId),
          MessageComposer(
            members: activeMembers,
            enabled: !archived,
            replyTarget: _replyTarget,
            onCancelReply: () => setState(() => _replyTarget = null),
            editTarget: _editTarget,
            onCancelEdit: () => setState(() => _editTarget = null),
            onSend: _send,
            attachments: _pending,
            // 封存房唯讀，附件入口一併收起
            onPickFiles: archived ? null : _pickFiles,
            onPasteImage: archived ? null : _pasteImage,
            onRemoveAttachment: _removePending,
            onRetryAttachment: _retryPending,
          ),
        ],
      ),
    );

    if (!wide) {
      return Scaffold(
        backgroundColor: s.bg,
        endDrawer: Drawer(
          backgroundColor: s.bgSoft,
          child: SafeArea(
            child: _MembersPanel(
              roomId: roomId,
              members: members,
              myId: myId,
              archived: archived,
              limits: detailAsync.value?.limits ?? const ServerLimits(),
              youAreAdmin: detailAsync.value?.youAreAdmin ?? false,
            ),
          ),
        ),
        body: chatColumn,
      );
    }
    return Scaffold(
      backgroundColor: s.bg,
      body: Row(
        children: [
          Expanded(child: chatColumn),
          Container(
            width: 288,
            decoration: BoxDecoration(
              color: s.bgSoft,
              border: Border(left: BorderSide(color: s.line)),
            ),
            child: _MembersPanel(
              roomId: roomId,
              members: members,
              myId: myId,
              archived: archived,
              limits: detailAsync.value?.limits ?? const ServerLimits(),
              youAreAdmin: detailAsync.value?.youAreAdmin ?? false,
            ),
          ),
        ],
      ),
    );
  }

  /// 桌面才掛拖放。desktop_drop 只實作 windows/macos/linux/web，在 Android
  /// 上掛了會在通道呼叫時炸 MissingPluginException——那是「有支援才掛」而不是
  /// 「掛了再處理錯誤」的情境。
  Widget _withDropTarget(UepSurface s, Widget child) {
    final isDesktop =
        !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.windows ||
            defaultTargetPlatform == TargetPlatform.macOS ||
            defaultTargetPlatform == TargetPlatform.linux);
    if (!isDesktop) return child;
    return DropTarget(
      onDragEntered: (_) => setState(() => _dragging = true),
      onDragExited: (_) => setState(() => _dragging = false),
      onDragDone: (detail) {
        setState(() => _dragging = false);
        _dropFiles(detail.files);
      },
      child: Stack(
        children: [
          child,
          if (_dragging)
            Positioned.fill(
              child: IgnorePointer(
                child: Container(
                  color: UepColors.gold.withValues(alpha: .08),
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 12,
                      ),
                      decoration: BoxDecoration(
                        color: s.bgCard,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: UepColors.gold),
                      ),
                      child: MonoLabel(
                        '放開以附加檔案',
                        size: 10,
                        color: UepColors.gold,
                        letterSpacing: 2.0,
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _desaturateIfArchived(bool archived, Widget child) {
    if (!archived) return child;
    // 設計稿：封存房內容 saturate(.35)
    const sat = 0.35;
    const r = 0.2126, g = 0.7152, b = 0.0722;
    return ColorFiltered(
      colorFilter: const ColorFilter.matrix([
        r + (1 - r) * sat,
        g * (1 - sat),
        b * (1 - sat),
        0,
        0,
        r * (1 - sat),
        g + (1 - g) * sat,
        b * (1 - sat),
        0,
        0,
        r * (1 - sat),
        g * (1 - sat),
        b + (1 - b) * sat,
        0,
        0,
        0,
        0,
        0,
        1,
        0,
      ]),
      child: child,
    );
  }
}

// ---------- header ----------

class _RoomHeader extends ConsumerWidget {
  const _RoomHeader({
    required this.roomId,
    required this.roomName,
    required this.topic,
    required this.archived,
    required this.zoneLabel,
    required this.zoneColor,
    required this.zoneStroke,
    required this.pinnedCount,
    required this.memberCount,
    required this.showMembersButton,
  });

  final String roomId;
  final String roomName;
  final String topic;
  final bool archived;
  final String zoneLabel;
  final Color zoneColor;
  final Color zoneStroke;
  final int pinnedCount;
  final int memberCount;
  final bool showMembersButton;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.uep;
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 14, 18, 12),
      decoration: BoxDecoration(
        color: archived ? s.bgSoft : null,
        border: Border(bottom: BorderSide(color: s.line)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        roomName,
                        overflow: TextOverflow.ellipsis,
                        style: UepText.display(
                          size: 26,
                          color: archived ? s.inkSoft : s.inkTitle,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        border: Border.all(
                          color: archived ? s.lineStrong : zoneStroke,
                        ),
                      ),
                      child: MonoLabel(
                        archived ? 'ARCHIVED' : zoneLabel,
                        size: 9,
                        color: archived ? s.inkMute : zoneColor,
                        letterSpacing: 1.4,
                      ),
                    ),
                  ],
                ),
                if (topic.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    '主題：$topic',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: UepText.serif(
                      size: 12.5,
                      color: archived ? s.inkMute : s.inkSoft,
                      height: 1.5,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 16),
          if (archived)
            _HeaderAction(
              label: '解除封存',
              onTap: () async {
                try {
                  await ref.read(roomsApiProvider).unarchive(
                        roomId,
                        sessionKey: ref.read(appConfigProvider).deviceKey,
                        participantId: ref
                            .read(settingsRepoProvider)
                            .participantId(roomId),
                      );
                } on ApiException catch (e) {
                  // 解封是有門檻的動作，會被 Hub 擋。沒有這個 catch 的話
                  // 失敗只會拋進 framework，畫面上什麼都不會發生
                  if (context.mounted) {
                    ScaffoldMessenger.of(context)
                        .showSnackBar(SnackBar(content: Text(e.message)));
                  }
                  return;
                }
                ref.invalidate(roomDetailProvider(roomId));
                ref.invalidate(roomListProvider);
                // 封存期間 join 的 409 錯誤會被快取，解封後重新取得身分
                ref.invalidate(identityProvider(roomId));
                // feed 的房間狀態要等 WS 事件才會翻新；斷線時會卡在 archived
                ref.read(roomFeedProvider(roomId)).setRoomStatus('active');
              },
            )
          else ...[
            _HeaderAction(
              label: '❖ 釘選 $pinnedCount',
              onTap: () => context.go('/rooms/$roomId/pinned'),
            ),
            const SizedBox(width: 8),
            _HeaderAction(
              label: '指派',
              onTap: () => context.go('/rooms/$roomId/assign'),
            ),
            const SizedBox(width: 8),
            _OverflowMenu(roomId: roomId),
          ],
          if (showMembersButton) ...[
            const SizedBox(width: 8),
            Builder(
              builder: (context) => _HeaderAction(
                label: '成員 $memberCount',
                onTap: () => Scaffold.of(context).openEndDrawer(),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _HeaderAction extends StatelessWidget {
  const _HeaderAction({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(border: Border.all(color: s.line)),
        child: Text(
          label.toUpperCase(),
          style: UepText.mono(size: 10, color: s.inkSoft, letterSpacing: 1.4),
        ),
      ),
    );
  }
}

class _OverflowMenu extends ConsumerWidget {
  const _OverflowMenu({required this.roomId});

  final String roomId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.uep;
    // 鎖定是管理員限定的動作，非建立者連選項都不該看到——列出來再擋，
    // 只是把一個必然失敗的按鈕擺在那裡
    final detail = ref.watch(roomDetailProvider(roomId)).value;
    final youAreAdmin = detail?.youAreAdmin ?? false;
    // 主持人模式**只加開刪除**，不加開說話方式與鎖定狀態。
    //
    // Hub 那邊也是這樣分的：主持人視角放行「清掉這台 Hub 上的東西」
    // （封存／解封／刪除），不放行「以別人的房主身分行事」（改別人房間
    // 的說話方式、鎖定狀態、踢別人房裡的人）。UI 多給一顆按鈕，按下去
    // 只會拿到 403——把必然失敗的按鈕擺出來，跟不給一樣糟
    final canDelete = youAreAdmin || ref.watch(hostViewProvider);
    final isPrivate = detail?.room.isPrivate ?? false;
    final style = detail?.room.style ?? kRoomStyles.first.value;
    final styleInstructions = detail?.room.styleInstructions ?? '';
    return PopupMenuButton<String>(
      color: s.bgCard,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: s.lineStrong),
      ),
      onSelected: (v) async {
        switch (v) {
          case 'style':
            final picked = await showDialog<({String style, String text})>(
              context: context,
              builder: (_) =>
                  _StyleDialog(style: style, instructions: styleInstructions),
            );
            if (picked == null) return;
            try {
              await ref
                  .read(roomsApiProvider)
                  .setStyle(
                    roomId,
                    style: picked.style,
                    instructions: picked.text,
                    sessionKey: ref.read(appConfigProvider).deviceKey,
                    participantId: ref
                        .read(identityProvider(roomId))
                        .value
                        ?.participantId,
                  );
              ref.invalidate(roomDetailProvider(roomId));
              ref.invalidate(roomListProvider);
            } on ApiException catch (e) {
              if (context.mounted) {
                ScaffoldMessenger.of(context)
                    .showSnackBar(SnackBar(content: Text(e.message)));
              }
            }
          case 'visibility':
            try {
              await ref
                  .read(roomsApiProvider)
                  .setVisibility(
                    roomId,
                    visibility: isPrivate ? 'public' : 'private',
                    sessionKey: ref.read(appConfigProvider).deviceKey,
                    participantId: ref
                        .read(identityProvider(roomId))
                        .value
                        ?.participantId,
                  );
              ref.invalidate(roomDetailProvider(roomId));
              ref.invalidate(roomListProvider);
            } on ApiException catch (e) {
              if (context.mounted) {
                ScaffoldMessenger.of(context)
                    .showSnackBar(SnackBar(content: Text(e.message)));
              }
            }
          case 'delete':
            final name = detail?.room.name ?? '';
            final ok = await showDialog<bool>(
              context: context,
              builder: (_) => DeleteRoomConfirm(name: name),
            );
            if (ok != true) return;
            try {
              final counts = await ref
                  .read(roomsApiProvider)
                  .deleteRoom(
                    roomId,
                    sessionKey: ref.read(appConfigProvider).deviceKey,
                    participantId: ref
                        .read(identityProvider(roomId))
                        .value
                        ?.participantId,
                  );
              await ref
                  .read(settingsRepoProvider)
                  .setParticipantId(roomId, null);
              ref.invalidate(roomListProvider);
              if (context.mounted) {
                context.go('/rooms');
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      '已刪除「$name」'
                      '（訊息 ${counts['message'] ?? 0} 則、'
                      '附件 ${counts['attachment'] ?? 0} 個）',
                    ),
                  ),
                );
              }
            } on ApiException catch (e) {
              if (context.mounted) {
                ScaffoldMessenger.of(context)
                    .showSnackBar(SnackBar(content: Text(e.message)));
              }
            }
          case 'archive':
            try {
              final result = await ref.read(roomsApiProvider).archive(
                    roomId,
                    sessionKey: ref.read(appConfigProvider).deviceKey,
                    participantId:
                        ref.read(settingsRepoProvider).participantId(roomId),
                  );
              ref.invalidate(roomDetailProvider(roomId));
              ref.invalidate(roomListProvider);
              // 成員按下去是提議不是封存。不講清楚的話畫面毫無動靜，
              // 看起來像按鈕壞了
              if (!result.archived && context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                  content: Text(result.alreadyPending
                      ? '已經有人提議封存了，還在等建立者確認'
                      : '已送出封存請求，等建立者確認'),
                ));
              }
            } on ApiException catch (e) {
              if (context.mounted) {
                ScaffoldMessenger.of(context)
                    .showSnackBar(SnackBar(content: Text(e.message)));
              }
            }
          case 'leave':
            final identity = ref.read(identityProvider(roomId)).value;
            if (identity == null) return;
            try {
              await ref
                  .read(roomsApiProvider)
                  .leave(roomId, participantId: identity.participantId);
              await ref
                  .read(settingsRepoProvider)
                  .setParticipantId(roomId, null);
              ref.invalidate(identityProvider(roomId));
              ref.invalidate(roomDetailProvider(roomId));
              if (context.mounted) context.go('/rooms');
            } on ApiException catch (e) {
              if (context.mounted) {
                ScaffoldMessenger.of(context)
                    .showSnackBar(SnackBar(content: Text(e.message)));
              }
            }
        }
      },
      itemBuilder: (context) => [
        if (youAreAdmin)
          PopupMenuItem(
            value: 'style',
            height: 36,
            child: Text(
              '說話方式（${roomStyleLabel(style)}）',
              style: UepText.sans(size: 12.5, color: s.ink),
            ),
          ),
        if (youAreAdmin)
          PopupMenuItem(
            value: 'visibility',
            height: 36,
            child: Text(
              isPrivate ? '解除鎖定（改為公開）' : '鎖定為私人對話',
              style: UepText.sans(size: 12.5, color: s.ink),
            ),
          ),
        PopupMenuItem(
          value: 'archive',
          height: 36,
          child: Text('封存房間', style: UepText.sans(size: 12.5, color: s.ink)),
        ),
        PopupMenuItem(
          value: 'leave',
          height: 36,
          child: Text(
            '離開房間',
            style: UepText.sans(size: 12.5, color: UepColors.errorText),
          ),
        ),
        // 刪除排在最後、與其他項目隔開：它是這個選單裡唯一不可復原的動作
        if (canDelete)
          PopupMenuItem(
            value: 'delete',
            height: 36,
            child: Text(
              '永久刪除房間…',
              style: UepText.sans(size: 12.5, color: UepColors.errorText),
            ),
          ),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        decoration: BoxDecoration(border: Border.all(color: s.line)),
        child: Text('⋯', style: TextStyle(fontSize: 11, color: s.inkSoft)),
      ),
    );
  }
}

// ---------- pinned strip ----------

class _PinnedStrip extends StatelessWidget {
  const _PinnedStrip({required this.roomId, required this.latest});

  final String roomId;
  final Message latest;

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    return InkWell(
      onTap: () => context.go('/rooms/$roomId/pinned'),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 9),
        decoration: BoxDecoration(
          color: UepColors.gold.withValues(alpha: .06),
          border: Border(
            bottom: BorderSide(color: UepColors.gold.withValues(alpha: .18)),
          ),
        ),
        child: Row(
          children: [
            const Text(
              '❖',
              style: TextStyle(fontSize: 11, color: UepColors.gold),
            ),
            const SizedBox(width: 10),
            Text(
              'PINNED',
              style: UepText.mono(
                size: 9,
                color: UepColors.gold,
                letterSpacing: 1.6,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                '${latest.senderName ?? ''}：${latest.content}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: UepText.serif(size: 12.5, color: s.inkSoft, height: 1.4),
              ),
            ),
            MonoLabel('查看全部 →', size: 9, letterSpacing: 1.2),
          ],
        ),
      ),
    );
  }
}

// ---------- members panel ----------

class _MembersPanel extends ConsumerStatefulWidget {
  const _MembersPanel({
    required this.roomId,
    required this.members,
    required this.myId,
    required this.archived,
    required this.youAreAdmin,
    this.limits = const ServerLimits(),
  });

  final String roomId;
  final List<Participant> members;
  final String? myId;
  final bool archived;
  final bool youAreAdmin;

  /// 伺服器實際生效的門檻（閒置移出倒數要用它，不能寫死）。
  final ServerLimits limits;

  @override
  ConsumerState<_MembersPanel> createState() => _MembersPanelState();
}

class _MembersPanelState extends ConsumerState<_MembersPanel> {
  /// 被我從列表隱藏的成員。**純本機視圖**——不送去 Hub，不影響聊天內容、
  /// mention、歷史或任何人的成員資料。房間開久了離開過的身分會越積越多，
  /// 但那些記錄在 Hub 端仍有用途（歷史訊息的身分對照），所以這裡做的是
  /// 「不畫」而不是「刪掉」。
  late Set<String> _hidden;

  /// 暫時把隱藏的人叫回來看。刻意不持久化——它是「我現在想看一下」，
  /// 不是一個偏好。
  bool _showHidden = false;

  @override
  void initState() {
    super.initState();
    _hidden = ref.read(settingsRepoProvider).hiddenMembers(widget.roomId);
  }

  @override
  void didUpdateWidget(_MembersPanel old) {
    super.didUpdateWidget(old);
    // 換房間時要換名單，否則會把上一個房的隱藏設定套在這個房上
    if (old.roomId != widget.roomId) {
      _hidden = ref.read(settingsRepoProvider).hiddenMembers(widget.roomId);
      _showHidden = false;
    }
  }

  Future<void> _toggleHighlight(Participant p) =>
      ref.read(highlightedMembersProvider.notifier)
          .toggle(widget.roomId, p.id);

  Future<void> _setHidden(Participant p, bool hide) async {
    final next = {..._hidden};
    if (hide) {
      next.add(p.id);
    } else {
      next.remove(p.id);
    }
    setState(() => _hidden = next);
    await ref.read(settingsRepoProvider).setHiddenMembers(widget.roomId, next);
  }

  Future<void> _inviteHuman(BuildContext context) async {
    final sent = await showDialog<bool>(
      context: context,
      builder: (_) =>
          InviteHumanDialog(roomId: widget.roomId, members: widget.members),
    );
    if ((sent ?? false) && context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('邀請已送出，對方接受後會加入這個聊天室')));
    }
  }

  Future<void> _kick(BuildContext context, Participant p) async {
    final s = context.uep;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          '將 ${p.displayName} 移出聊天室？',
          style: UepText.display(size: 22, color: s.inkTitle),
        ),
        content: Text(
          '被移出後，這個 session 將無法重新加入此聊天室。此操作無法復原。',
          style: UepText.serif(size: 13.5, color: s.inkSoft),
        ),
        actions: [
          UepButton(
            label: '取消',
            variant: UepButtonVariant.outline,
            small: true,
            onPressed: () => Navigator.of(context).pop(false),
          ),
          UepButton(
            label: '移出',
            variant: UepButtonVariant.danger,
            small: true,
            onPressed: () => Navigator.of(context).pop(true),
          ),
        ],
      ),
    );
    final myId = widget.myId;
    if (!(confirmed ?? false) || myId == null) return;
    try {
      await ref
          .read(roomsApiProvider)
          .kick(widget.roomId, targetId: p.id, participantId: myId);
      ref.invalidate(roomDetailProvider(widget.roomId));
    } on ApiException catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
      }
    }
  }

  /// 主持人接管管理權。
  ///
  /// 要確認：這會讓現任管理員降為一般成員，而他可能正在用這個房。
  /// 但它**不是**破壞性的——管理權可以再移交回去，所以用 outline 不用 danger。
  Future<void> _claimAdmin(BuildContext context, Participant? current) async {
    final s = context.uep;
    final who = current?.displayName;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('接管這個聊天室？',
            style: UepText.display(size: 22, color: s.inkTitle)),
        content: Text(
          who == null
              ? '這個聊天室目前沒有管理員。接管之後你就是它的管理員，'
                  '不必再開主持人模式也管得動。'
              : '$who 目前是這個聊天室的管理員，接管之後他會降為一般成員。'
                  '房內會留下一則系統訊息，管理權之後可以再移交回去。',
          style: UepText.serif(size: 13.5, color: s.inkSoft, height: 1.6),
        ),
        actions: [
          UepButton(
            label: '取消',
            variant: UepButtonVariant.outline,
            small: true,
            onPressed: () => Navigator.of(context).pop(false),
          ),
          UepButton(
            label: '接管',
            small: true,
            onPressed: () => Navigator.of(context).pop(true),
          ),
        ],
      ),
    );
    if (!(confirmed ?? false)) return;
    try {
      final changed = await ref.read(roomsApiProvider).claimAdmin(
            widget.roomId,
            sessionKey: ref.read(appConfigProvider).deviceKey,
          );
      ref.invalidate(roomDetailProvider(widget.roomId));
      ref.invalidate(roomListProvider);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(changed ? '你現在是這個聊天室的管理員' : '這個聊天室本來就是你的'),
        ));
      }
    } on ApiException catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    final myId = widget.myId;
    final highlighted =
        ref.watch(highlightedMembersProvider)[widget.roomId] ?? const <String>{};
    final hostMode = ref.watch(hostViewProvider);
    final shown = widget.members.where((p) => !_hidden.contains(p.id));
    final active = shown.where((p) => p.isActive).toList();
    // **結束的子代理不進「已離開」。** 一般成員離開是有意義的資訊（他還會
    // 回來、他的話還在），而子代理是一次性的臨時分身——它結束就是它該消失，
    // 留一塊墓碑只會把成員列撐長，而且每派一次就多一塊
    final gone = shown.where((p) => !p.isActive && !p.ephemeral).toList();
    final hidden = widget.members.where((p) => _hidden.contains(p.id)).toList();

    return Column(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(vertical: 13),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: s.line)),
          ),
          width: double.infinity,
          child: Stack(
            alignment: Alignment.center,
            children: [
              MonoLabel(
                '成員 ${active.length}',
                size: 9,
                color: UepColors.gold,
                letterSpacing: 1.6,
              ),
              if (hidden.isNotEmpty)
                Positioned(
                  right: 4,
                  child: IconButton(
                    tooltip: _showHidden
                        ? '收起已隱藏的成員'
                        : '顯示已隱藏的成員（${hidden.length}）',
                    visualDensity: VisualDensity.compact,
                    constraints: const BoxConstraints(),
                    padding: EdgeInsets.zero,
                    onPressed: () => setState(() => _showHidden = !_showHidden),
                    icon: Icon(
                      _showHidden
                          ? Icons.visibility_off_outlined
                          : Icons.visibility_outlined,
                      size: 14,
                      color: s.inkMute,
                    ),
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(14, 16, 14, 16),
            children: [
              MonoLabel('ACTIVE', size: 8.5, letterSpacing: 2.2),
              const SizedBox(height: 8),
              for (final p in nestSubagents(active))
                _MemberTile(
                  p: p,
                  isSelf: p.id == myId,
                  nested: p.ephemeral,
                  idleTimeout: widget.limits.idleTimeout,
                  // subagent 不給踢：它沒有獨立的存在，要它走就讓它的
                  // 父層走（父層一離開，旗下的會一起消失）
                  onKick:
                      widget.youAreAdmin &&
                          p.id != myId &&
                          !widget.archived &&
                          !p.ephemeral
                      ? () => _kick(context, p)
                      : null,
                  // 接管掛在**現任管理員**身上，與移交同一個位置。
                  // 封存房也給——需要接管的房多半已經被收起來了
                  onClaimAdmin: hostMode && p.isAdmin && p.id != myId
                      ? () => _claimAdmin(context, p)
                      : null,
                  // 自己隱藏自己只會讓人以為出了問題
                  onHide: p.id == myId ? null : () => _setHidden(p, true),
                  // 標記只給別人：不會有人在等自己回話
                  highlighted: highlighted.contains(p.id),
                  onToggleHighlight:
                      p.id == myId ? null : () => _toggleHighlight(p),
                ),
              if (gone.isNotEmpty) ...[
                const SizedBox(height: 16),
                MonoLabel('已離開', size: 8.5, letterSpacing: 2.2),
                const SizedBox(height: 8),
                for (final p in gone)
                  Opacity(
                    opacity: .45,
                    child: _MemberTile(
                      p: p,
                      isSelf: false,
                      inactive: true,
                      onHide: () => _setHidden(p, true),
                    ),
                  ),
              ],
              if (_showHidden && hidden.isNotEmpty) ...[
                const SizedBox(height: 16),
                MonoLabel('已隱藏', size: 8.5, letterSpacing: 2.2),
                const SizedBox(height: 8),
                for (final p in hidden)
                  Opacity(
                    opacity: .35,
                    child: _MemberTile(
                      p: p,
                      isSelf: p.id == myId,
                      inactive: !p.isActive,
                      idleTimeout: widget.limits.idleTimeout,
                      onUnhide: () => _setHidden(p, false),
                    ),
                  ),
              ],
            ],
          ),
        ),
        // 沒有任何管理員的房（creator_session_key 為 NULL 的舊房）——
        // 那正是**最需要**接管的那些，而成員列表上沒有人掛得住那顆按鈕。
        // 只有這種情況才在底部另開入口，房內有管理員時一律走他身上那顆，
        // 免得同一個動作有兩個位置
        if (hostMode && !active.any((p) => p.isAdmin))
          Container(
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 0),
            child: UepButton(
              label: '接管這個聊天室',
              variant: UepButtonVariant.outline,
              small: true,
              expand: true,
              onPressed: () => _claimAdmin(context, null),
            ),
          ),
        // 底部動作區。匯出**不**跟著封存收起——房間可以被永久刪除，備份
        // 正是封存之後最需要的動作；指派與邀請則唯讀時收起。
        //
        // ⚠️ 三顆鈕包在同一個 Container 裡，不是各自一個：匯出原本自己帶
        // `bottom: 0` 的 padding，靠下面那塊的 14 撐出底部留白，於是封存房
        // （下面那塊整個不渲染）就變成按鈕直接貼著視窗底邊，而且少了上緣的
        // 分隔線。留白不可以外包給一個條件渲染的鄰居。
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: s.line)),
          ),
          child: Column(
            children: [
              ExportRoomButton(roomId: widget.roomId),
              if (!widget.archived) ...[
                const SizedBox(height: 8),
                UepButton(
                  label: '指派 AGENT 加入',
                  variant: UepButtonVariant.outline,
                  small: true,
                  expand: true,
                  onPressed: () => context.go('/rooms/${widget.roomId}/assign'),
                ),
                const SizedBox(height: 8),
                UepButton(
                  label: '邀請成員加入',
                  variant: UepButtonVariant.outline,
                  small: true,
                  expand: true,
                  onPressed: () => _inviteHuman(context),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _MemberTile extends StatelessWidget {
  const _MemberTile({
    required this.p,
    required this.isSelf,
    this.inactive = false,
    this.nested = false,
    this.onKick,
    this.onClaimAdmin,
    this.onHide,
    this.onUnhide,
    this.highlighted = false,
    this.onToggleHighlight,
    this.idleTimeout = const Duration(minutes: 10),
  });

  final Participant p;
  final bool isSelf;
  final bool inactive;

  /// 這是掛在別人底下的子代理：縮排、線條虛化，讓「它不是獨立成員」
  /// 一眼看得出來。
  final bool nested;

  /// 伺服器實際的閒置移出門檻。**不要寫死**——它是可設定的，猜錯就會顯示
  /// 一個永遠不會發生的倒數（設 30 分鐘卻顯示 10 分鐘後移出）。
  final Duration idleTimeout;

  /// 管理員視角的移出動作；null 表示不顯示。
  final VoidCallback? onKick;

  /// Hub 主持人接管這個房間的管理權。只掛在**現任管理員**身上，
  /// 與移交同一個位置——那是使用者找這個動作時會去看的地方。
  final VoidCallback? onClaimAdmin;

  /// 從**我這台裝置**的列表隱藏／取消隱藏；null 表示不顯示該動作。
  /// 與 [onKick] 完全不同：那個動到所有人，這個只動我的視圖。
  final VoidCallback? onHide;
  final VoidCallback? onUnhide;

  /// 這個人被我標記為重點（時間軸上的左軸會加粗）。與隱藏同一類：
  /// 純本機視圖，方向相反——隱藏是「別讓他佔位置」，標記是「別讓我漏看他」。
  final bool highlighted;
  final VoidCallback? onToggleHighlight;

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    final color = kindColor(p.kind, context: context);
    final lastSeen = parseIso(p.lastSeenAt);
    final idleMinutes = lastSeen == null
        ? null
        : DateTime.now().difference(lastSeen).inMinutes;
    final isIdle = !inactive && !p.isHuman && (idleMinutes ?? 0) >= 2;

    String subtitle;
    if (nested && !inactive) {
      // 不沿用一般成員那套倒數：subagent 走的是完全不同的短時限，
      // 顯示父層的門檻等於印一個永遠不會發生的倒數
      subtitle = '臨時 · 工作結束即移除';
    } else if (inactive) {
      subtitle = switch (p.status) {
        'removed' => '因閒置移出',
        'kicked' => '被管理員移出',
        _ => '已離開',
      };
    } else if (isSelf) {
      subtitle = '你 · 管控權';
    } else if (isIdle) {
      final remain = idleTimeout.inMinutes - idleMinutes!;
      subtitle = remain > 0
          ? '閒置 $idleMinutes 分 · $remain 分後移出'
          : '閒置 $idleMinutes 分';
    } else {
      subtitle = '活躍 · ${relativeTime(p.lastSeenAt)}';
    }

    final menuActions = <_MemberAction>[
      if (onHide != null)
        _MemberAction('從我的列表隱藏', Icons.visibility_off_outlined, onHide!),
      if (onUnhide != null)
        _MemberAction('取消隱藏', Icons.visibility_outlined, onUnhide!),
      if (onClaimAdmin != null)
        _MemberAction('接管管理權（主持人）', Icons.admin_panel_settings_outlined,
            onClaimAdmin!, color: UepColors.gold),
      if (onKick != null)
        _MemberAction('移出聊天室', Icons.person_remove_outlined, onKick!),
    ];

    return Opacity(
      opacity: isIdle ? .6 : 1,
      child: Container(
        margin: EdgeInsets.only(bottom: 4, left: nested ? 16 : 0),
        padding: EdgeInsets.fromLTRB(nested ? 8 : 10, nested ? 7 : 9, 8,
            nested ? 7 : 9),
        decoration: BoxDecoration(
          color: isSelf ? UepColors.gold.withValues(alpha: .06) : null,
          border: Border(
            left: BorderSide(
              color: inactive
                  ? s.hairline
                  // 子代理的線條淡一階：它不是獨立成員，視覺重量也不該
                  // 跟派它出來的那個一樣
                  : (nested ? color.withValues(alpha: .45) : color),
              width: nested ? 1 : 2,
            ),
          ),
          borderRadius: const BorderRadius.horizontal(
            right: Radius.circular(4),
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          p.displayName,
                          overflow: TextOverflow.ellipsis,
                          style: UepText.sans(
                            size: 13,
                            weight: FontWeight.w600,
                            color: inactive ? s.ink : s.inkTitle,
                          ),
                        ),
                      ),
                      const SizedBox(width: 7),
                      if (nested)
                        // 只縮排的話，「為什麼這個名字沒看過」得靠讀者自己
                        // 推理。講出來便宜得多
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 5,
                            vertical: 1,
                          ),
                          decoration: BoxDecoration(
                            border: Border.all(color: s.hairline),
                            borderRadius: BorderRadius.circular(3),
                          ),
                          child: Text(
                            '子代理',
                            style: UepText.sans(size: 9, color: s.inkMute),
                          ),
                        )
                      else
                        KindBadge(kind: p.kind, compact: true),
                      // 主持人與建立者是兩個**不同**的身分，兩顆都掛：
                      // HOST＝這台 Hub 是他的，ADMIN＝這個房是他開的。
                      // 合成一顆「管理員」會讓「誰能封這個房」與「誰能看
                      // 所有房」變得分不出來
                      if (p.showsHostBadge) ...[
                        const SizedBox(width: 5),
                        _RoleBadge(label: 'HOST', color: UepColors.gold),
                      ],
                      if (p.isAdmin) ...[
                        const SizedBox(width: 5),
                        _RoleBadge(label: 'ADMIN', color: s.inkMute),
                      ],
                      if (p.previousName != null) ...[
                        const SizedBox(width: 7),
                        Flexible(
                          child: Text(
                            '（原：${p.previousName}）',
                            overflow: TextOverflow.ellipsis,
                            style: UepText.serif(size: 11, color: s.inkMute),
                          ),
                        ),
                      ],
                      if (p.distinctHint != null) ...[
                        const SizedBox(width: 7),
                        Flexible(
                          child: Text(
                            '（${p.distinctHint}）',
                            overflow: TextOverflow.ellipsis,
                            style: UepText.mono(size: 9, color: s.inkMute),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    subtitle,
                    style: UepText.mono(
                      size: 9,
                      color: isSelf ? UepColors.gold : s.inkMute,
                      letterSpacing: 1.0,
                    ),
                  ),
                ],
              ),
            ),
            if (!inactive)
              Container(
                width: 6,
                height: 6,
                margin: const EdgeInsets.only(top: 2),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: isSelf
                      ? UepColors.gold
                      : isIdle
                      ? Colors.transparent
                      : UepColors.success,
                  border: isIdle ? Border.all(color: s.inkMute) : null,
                ),
              ),
            if (onToggleHighlight != null)
              IconButton(
                tooltip: highlighted ? '取消標記' : '標記這個人（時間軸上加粗）',
                visualDensity: VisualDensity.compact,
                onPressed: onToggleHighlight,
                icon: Icon(
                  highlighted ? Icons.star : Icons.star_border,
                  size: 14,
                  color: highlighted ? color : s.inkMute,
                ),
              ),
            // 其餘動作收進選單。名字長一點的成員（agent 那些）在這個寬度下
            // 本來就只剩一行的餘裕，四顆圖示並排會把名字擠成省略號。
            // 標記留在外面沒有收進來：它同時是**狀態顯示**，收進選單就看不
            // 出誰被標記了。
            if (menuActions.isNotEmpty)
              PopupMenuButton<VoidCallback>(
                tooltip: '更多動作',
                padding: EdgeInsets.zero,
                iconSize: 14,
                splashRadius: 14,
                position: PopupMenuPosition.under,
                icon: Icon(Icons.more_horiz, size: 14, color: s.inkMute),
                onSelected: (cb) => cb(),
                itemBuilder: (_) => [
                  for (final a in menuActions)
                    PopupMenuItem<VoidCallback>(
                      value: a.onTap,
                      height: 36,
                      child: Row(
                        children: [
                          Icon(a.icon, size: 14, color: a.color ?? s.inkMute),
                          const SizedBox(width: 8),
                          Text(
                            a.label,
                            style: UepText.sans(
                              size: 12,
                              color: a.color ?? s.ink,
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

/// 指名問「我」的待答問題。
///
/// 位置刻意在輸入框正上方而不是訊息流裡：問題是待辦不是對話，混進時間軸會被
/// 後續訊息推走看不見——而「人沒看到」正是 agent 轉回自己 session 重複發問的
/// 起點，也就是這整個機制要消除的東西。
class _PendingQuestions extends ConsumerStatefulWidget {
  const _PendingQuestions({required this.roomId, required this.participantId});

  final String roomId;
  final String participantId;

  @override
  ConsumerState<_PendingQuestions> createState() => _PendingQuestionsState();
}

class _PendingQuestionsState extends ConsumerState<_PendingQuestions> {
  /// 暫時收合。**不持久化**——它是「我現在想先看聊天」，不是一個偏好；
  /// 而未答的問題一直存在，下次進房該重新看到。
  bool _collapsed = false;

  Future<void> _respond(String id, String kind, String answer,
      [List<String> selected = const [],
      List<String> attachmentIds = const []]) async {
    try {
      await ref
          .read(questionsApiProvider)
          .answer(
            id,
            kind: kind,
            answer: answer,
            selected: selected,
            attachmentIds: attachmentIds,
            participantId: widget.participantId,
          );
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('回答失敗：${e.message}')));
    }
  }

  /// 回答問題時選檔並上傳。走與訊息附件同一條 API——附件屬於房間而不是
  /// 訊息，所以上傳完就可以掛到答案上（Hub 會驗它屬於這個房）。
  Future<List<UploadedAttachment>> _pickAnswerFiles() async {
    // file_picker 12 起 pickFiles 是靜態方法，取消時回空 list 而不是 null
    final files = await FilePicker.pickFiles();
    final api = ref.read(attachmentsApiProvider);
    final out = <UploadedAttachment>[];
    for (final f in files) {
      final path = f.path;
      if (path == null) continue;
      try {
        out.add(await api.uploadPath(
          widget.roomId,
          participantId: widget.participantId,
          path: path,
          filename: f.name,
        ));
      } on ApiException catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('${f.name} 上傳失敗：${e.message}')));
        }
      }
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    final questions =
        ref.watch(roomQuestionsProvider(widget.roomId)).value ?? const [];
    if (questions.isEmpty) return const SizedBox.shrink();

    return Container(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: s.line)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 標題列在收合時仍然看得見——問題被藏起來而沒有任何痕跡的話，
          // 就回到了這整個機制要消除的那件事：人沒看到，agent 重複發問
          InkWell(
            onTap: () => setState(() => _collapsed = !_collapsed),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 12, 8),
              child: Row(
                children: [
                  MonoLabel(
                    '待答問題 ${questions.length}',
                    size: 9,
                    color: UepColors.gold,
                    letterSpacing: 1.6,
                  ),
                  const Spacer(),
                  MonoLabel(
                    _collapsed ? '展開' : '收合',
                    size: 8.5,
                    color: s.inkMute,
                    letterSpacing: 1.4,
                  ),
                  const SizedBox(width: 6),
                  Icon(
                    _collapsed ? Icons.expand_less : Icons.expand_more,
                    size: 15,
                    color: s.inkMute,
                  ),
                ],
              ),
            ),
          ),
          if (!_collapsed)
            ConstrainedBox(
              // 不限高的話，多題或長題會把輸入框整個擠出畫面，而外層是
              // Column 不能捲——使用者既看不完問題也打不了字（實機回報）
              constraints: BoxConstraints(
                maxHeight: (MediaQuery.sizeOf(context).height * .4).clamp(
                  160.0,
                  420.0,
                ),
              ),
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.only(bottom: 4),
                children: [
                  for (final q in questions)
                    QuestionCard(
                      question: q,
                      onAnswer: (kind, answer, selected, files) =>
                          _respond(q.id, kind, answer, selected, files),
                      onSkip: () => _respond(q.id, 'skip', ''),
                      onPickFiles: _pickAnswerFiles,
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// 變更說話方式。回傳 (style, text)；取消時回 null。
///
/// 自訂的內容**留在對話框裡**而不是選了才問：切到自訂再跳出第二個視窗，
/// 使用者會先失去剛剛看的那四個說明。
class _StyleDialog extends StatefulWidget {
  const _StyleDialog({required this.style, required this.instructions});

  final String style;
  final String instructions;

  @override
  State<_StyleDialog> createState() => _StyleDialogState();
}

class _StyleDialogState extends State<_StyleDialog> {
  late String _style = widget.style;
  late final _text = TextEditingController(text: widget.instructions);
  String? _error;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _submit() {
    final text = _text.text.trim();
    if (_style == kRoomStyleCustom && text.isEmpty) {
      setState(() => _error = '選擇自訂說話方式時要寫下指示內容');
      return;
    }
    Navigator.of(context).pop((style: _style, text: text));
  }

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    return AlertDialog(
      title: Text('說話方式', style: UepText.display(size: 22, color: s.inkTitle)),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '房內 agent 怎麼跟大家說話。改動會在房裡留下一則系統訊息。',
                  style: UepText.serif(size: 12, color: s.inkMute, height: 1.5),
                ),
              ),
              const SizedBox(height: 12),
              RoomStylePicker(
                value: _style,
                onChanged: (v) => setState(() {
                  _style = v;
                  _error = null;
                }),
              ),
              if (_style == kRoomStyleCustom) ...[
                const SizedBox(height: 8),
                Container(
                  decoration: BoxDecoration(
                    color: s.bgSunken,
                    border: Border.all(color: s.lineStrong),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: TextField(
                    controller: _text,
                    maxLines: 4,
                    style: UepText.serif(size: 13, color: s.ink, height: 1.7),
                    decoration: InputDecoration(
                      isDense: true,
                      border: InputBorder.none,
                      hintText: '例：一律用英文回答，句子不要超過兩行。',
                      hintStyle: UepText.serif(size: 12.5, color: s.inkMute),
                      contentPadding: const EdgeInsets.symmetric(vertical: 10),
                    ),
                  ),
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 10),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    _error!,
                    style: UepText.serif(
                      size: 12.5,
                      color: UepColors.errorText,
                      height: 1.5,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        UepButton(
          label: '取消',
          variant: UepButtonVariant.outline,
          small: true,
          onPressed: () => Navigator.of(context).pop(),
        ),
        UepButton(label: '套用', small: true, onPressed: _submit),
      ],
    );
  }
}

/// 成員列的「更多動作」選單項。
class _MemberAction {
  const _MemberAction(this.label, this.icon, this.onTap, {this.color});

  final String label;
  final IconData icon;
  final VoidCallback onTap;

  /// 需要強調時的顏色（接管管理權）；null 走預設的淡色。
  final Color? color;
}

/// 成員名字旁邊的身分標籤（HOST / ADMIN）。
///
/// 刻意做成外框而不是實心：實心的色塊在名字旁邊會搶掉名字本身，而這裡
/// 要回答的是「這個人是誰」，身分是附註。
class _RoleBadge extends StatelessWidget {
  const _RoleBadge({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        border: Border.all(color: color.withValues(alpha: .55)),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(
        label,
        style: UepText.mono(size: 8, color: color, letterSpacing: 1.1),
      ),
    );
  }
}
