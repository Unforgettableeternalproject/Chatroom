import 'package:chatroom_app/core/config/app_settings.dart';
import 'package:chatroom_app/models/message.dart';
import 'package:chatroom_app/notifications/notification_center.dart';
import 'package:chatroom_app/ws/room_feed.dart';
import 'package:flutter_test/flutter_test.dart';

Message msg(
  int seq, {
  String kind = 'chat',
  String? senderId = 'p-other',
  String sender = 'Novia',
  String content = 'hello',
  List<String> mentions = const [],
  bool deleted = false,
  String? systemEvent,
}) =>
    Message(
      id: 'm$seq',
      seq: seq,
      updateSeq: 0,
      kind: kind,
      content: content,
      createdAt: '',
      senderId: senderId,
      senderName: sender,
      mentions: mentions,
      deleted: deleted,
      systemEvent: systemEvent,
    );

void main() {
  late Map<String, RoomFeed> feeds;
  late NotificationCenter center;
  late List<RoomNotification> sent;
  late List<String> activity;

  final subscribedIds = <String, String?>{};
  // 每次「取得一份訂閱所有權」記一筆——底層 refCount 就是這樣加的
  final subscribeCalls = <String>[];
  final syncedIds = <String, String>{};
  RoomFeed subscribe(String roomId, {String? participantId}) {
    if (participantId != null) subscribedIds[roomId] = participantId;
    subscribeCalls.add(roomId);
    return feeds.putIfAbsent(roomId, () => RoomFeed(roomId));
  }

  void syncIdentity(String roomId, String participantId) {
    syncedIds[roomId] = participantId;
  }

  setUp(() {
    feeds = {};
    subscribedIds.clear();
    subscribeCalls.clear();
    syncedIds.clear();
    sent = [];
    activity = [];
    center = NotificationCenter(subscribe, (_) {}, syncIdentity);
    center.notifications.listen(sent.add);
    center.activity.listen(activity.add);
  });

  tearDown(() => center.dispose());

  Future<void> pump() => Future<void>.delayed(Duration.zero);

  test('首批快照只立基準線，不通知（歷史不轟炸）', () async {
    center.follow('r1', roomName: '設計討論');
    feeds['r1']!.upsertAll([msg(1), msg(2), msg(3)]);
    await pump();
    expect(sent, isEmpty);
    // 基準線之後的增量才通知
    feeds['r1']!.upsertAll([msg(4, content: '新訊息')]);
    await pump();
    expect(sent, hasLength(1));
    expect(sent.single.body, 'Novia：新訊息');
  });

  test('同一批多則合併為一則通知', () async {
    center.follow('r1', roomName: '設計討論');
    feeds['r1']!.upsertAll([msg(1)]);
    await pump();
    feeds['r1']!.upsertAll([msg(2), msg(3, content: '最後一句')]);
    await pump();
    expect(sent, hasLength(1));
    expect(sent.single.body, contains('2 則新訊息'));
    expect(sent.single.body, contains('最後一句'));
  });

  test('自己發的與 system 訊息不通知也不算活動', () async {
    center.follow('r1', roomName: '設計討論', myParticipantId: 'me');
    feeds['r1']!.upsertAll([msg(1)]);
    await pump();
    feeds['r1']!.upsertAll([
      msg(2, senderId: 'me'),
      msg(3, kind: 'system', senderId: null),
    ]);
    await pump();
    expect(sent, isEmpty);
    expect(activity, isEmpty);
  });

  test('自己發的訊息仍要進 fresh——Codex 轉送靠的就是這一條', () async {
    // 人類在這個 App 裡 @ 本機 Codex，那則的 sender 就是自己。fresh 若共用
    // 「不通知自己」的過濾結果，本機 Codex 永遠收不到同一台機器上的人對它
    // 說的話，而且完全沒有錯誤跡象。
    final batches = <RoomFreshBatch>[];
    center.fresh.listen(batches.add);
    center.follow('r1', roomName: '設計討論', myParticipantId: 'me');
    feeds['r1']!.upsertAll([msg(1)]);
    await pump();
    batches.clear();
    activity.clear();

    feeds['r1']!.upsertAll([msg(2, senderId: 'me', content: '@Codex 看一下')]);
    await pump();

    expect(batches, hasLength(1), reason: '自己發的訊息要送到轉送出口');
    expect(batches.single.messages.single.content, '@Codex 看一下');
    expect(sent, isEmpty, reason: 'OS 通知不該通知自己');
    expect(activity, isEmpty, reason: '未讀提示也不該把自己算成活動');
  });

  test('follow 把身分傳給底層訂閱——定向問題才推得過來', () async {
    center.follow('r1', roomName: 'A', myParticipantId: 'p1');
    expect(subscribedIds['r1'], 'p1');
  });

  test('先跟房、之後才拿到身分：補送身分但不再取得訂閱', () async {
    center.follow('r1', roomName: 'A');
    expect(syncedIds['r1'], isNull);
    // join 完成後帶著身分再 follow 一次（bootstrap 的正常時序）
    center.follow('r1', roomName: 'A', myParticipantId: 'p1');
    expect(syncedIds['r1'], 'p1',
        reason: '不補送的話 server 那條訂閱永遠是匿名的');
    expect(subscribeCalls, ['r1'],
        reason: '補身分走同步出口，不得再取得一份訂閱所有權');
  });

  test('房間列表反覆刷新不把訂閱計數灌高', () async {
    // bootstrap 對「所有已加入的房」呼叫 follow，而 roomList 每次刷新都會
    // 重跑一遍。follow 是冪等的，只有第一次該取得訂閱所有權——否則底層
    // refCount 單向累積，retainOnly 只減一次就永遠歸不了零，房間被移出或
    // 封存之後仍被背景訂閱著，而且畫面上完全看不出異狀。
    for (var i = 0; i < 5; i++) {
      center.follow('r1', roomName: 'A', myParticipantId: 'p1');
    }
    expect(subscribeCalls, ['r1']);
    expect(syncedIds['r1'], 'p1');
  });

  test('有人加入要送進轉送出口，但不是 OS 通知也不算未讀', () async {
    // 用 App 當通知樞紐的本機 agent 沒有自己的 watcher 進程；加入事件不
    // 放行的話，只有另外掛 watch.py 的 agent 收得到「房裡多了誰」。
    final batches = <RoomFreshBatch>[];
    center.fresh.listen(batches.add);
    center.follow('r1', roomName: 'A', myParticipantId: 'me');
    feeds['r1']!.upsertAll([msg(1)]);
    await pump();
    batches.clear();
    activity.clear();
    sent.clear();

    feeds['r1']!.upsertAll([
      msg(2,
          kind: 'system',
          systemEvent: 'join',
          senderId: 'p-new',
          sender: '測試Novia',
          content: '測試Novia 加入了聊天室'),
    ]);
    await pump();

    expect(batches, hasLength(1), reason: '加入事件要能喚醒房內的本機 agent');
    expect(batches.single.messages.single.isMemberJoined, isTrue);
    expect(sent, isEmpty, reason: '加入不是給人看的通知');
    expect(activity, isEmpty, reason: '也不該把加入算成未讀活動');
  });

  test('本機人類自己加入，也要送進 agent 出口', () async {
    // 這裡的「自己」是本機人類的 App 身分，而 fresh 的收件人是同一台機器
    // 上的 agent——人類加入房間，正是該通知本機 agent 的那一則。拿人類的
    // self-filter 去砍 agent 的出口，就是 B1 那個 bug 換位置重演。
    // Codex 自己加入不叫醒自己，是 CodexDispatcher 的職責（它才分得出
    // 哪個 thread 對應哪個加入者），不在這一層做。
    final batches = <RoomFreshBatch>[];
    center.fresh.listen(batches.add);
    center.follow('r1', roomName: 'A', myParticipantId: 'me');
    feeds['r1']!.upsertAll([msg(1)]);
    await pump();
    batches.clear();
    sent.clear();
    activity.clear();

    feeds['r1']!.upsertAll([
      msg(2,
          kind: 'system',
          systemEvent: 'join',
          senderId: 'me',
          sender: 'Bernie',
          content: 'Bernie 加入了聊天室'),
    ]);
    await pump();
    expect(batches, hasLength(1),
        reason: '同一台機器上的 agent 要知道這個人類進來了');
    expect(sent, isEmpty, reason: '但不必用 OS 通知打擾這個人類自己');
    expect(activity, isEmpty);
  });

  test('訂閱早於 join：加入訊息已躺在暖 feed 裡，仍恰好補投一次', () async {
    // 這是正常首次進房的時序：roomFeedProvider 先以 null 身分訂閱，
    // identityProvider 才 POST join，而 Hub 在回應之前就 post 了加入訊息。
    // 那則於是進了暖 feed，接著被「首批快照只立基準線」當成歷史吃掉。
    final batches = <RoomFreshBatch>[];
    center.fresh.listen(batches.add);
    final feed = subscribe('r1');
    feed.upsertAll([
      msg(1),
      msg(2,
          kind: 'system',
          systemEvent: 'join',
          senderId: 'me',
          sender: 'Bernie'),
    ]);
    center.follow('r1', roomName: 'A', myParticipantId: 'me');
    await pump();
    expect(batches, isEmpty, reason: '還沒登記之前，它就只是歷史');

    // join 回應回來了，帶著那則訊息的精確 id
    center.expectJoin('r1', 'm2');
    await pump();
    expect(batches, hasLength(1));
    expect(batches.single.messages.single.id, 'm2');

    // 消費一次就沒了，後續變更不得再投它
    batches.clear();
    feeds['r1']!.upsertAll([msg(3)]);
    await pump();
    expect(batches.single.messages.map((m) => m.id), ['m3']);
  });

  test('沒有登記的歷史加入事件不重播（App 重啟不轟炸）', () async {
    // 補投只認「這次 join 產生的那一筆」。若改用時間窗之類的模糊判準，
    // 每次 App 啟動都會把各房的歷史加入事件重播給 agent。
    final batches = <RoomFreshBatch>[];
    center.fresh.listen(batches.add);
    final feed = subscribe('r1');
    feed.upsertAll([
      msg(1,
          kind: 'system',
          systemEvent: 'join',
          senderId: 'p-old',
          sender: '很久以前的人'),
      msg(2),
    ]);
    center.follow('r1', roomName: 'A', myParticipantId: 'me');
    await pump();
    expect(batches, isEmpty);
  });

  test('加入訊息由 WS 增量送到時，補投機制不再送第二次', () async {
    final batches = <RoomFreshBatch>[];
    center.fresh.listen(batches.add);
    center.follow('r1', roomName: 'A', myParticipantId: 'me');
    feeds['r1']!.upsertAll([msg(1)]);
    await pump();
    batches.clear();

    // 先登記，但 feed 還沒有它——競態的另一半
    center.expectJoin('r1', 'm2');
    feeds['r1']!.upsertAll([
      msg(2, kind: 'system', systemEvent: 'join', senderId: 'me'),
    ]);
    await pump();
    expect(batches, hasLength(1), reason: '走正常增量路徑送達');

    batches.clear();
    feeds['r1']!.upsertAll([msg(3)]);
    await pump();
    expect(batches.single.messages.map((m) => m.id), ['m3'],
        reason: '登記已在增量路徑作廢，不得補投第二次');
  });

  test('其他 system 事件不進轉送出口', () async {
    // 放行的只有 join。離開／踢出／封存都不該喚醒 agent——離場那條走的是
    // watcher 的 departure 事件，不是這裡。
    final batches = <RoomFreshBatch>[];
    center.fresh.listen(batches.add);
    center.follow('r1', roomName: 'A', myParticipantId: 'me');
    feeds['r1']!.upsertAll([msg(1)]);
    await pump();
    batches.clear();

    feeds['r1']!.upsertAll([
      msg(2, kind: 'system', systemEvent: 'leave', senderId: null),
      msg(3, kind: 'system', systemEvent: 'kick', senderId: null),
      msg(4, kind: 'system', senderId: null),
    ]);
    await pump();
    expect(batches, isEmpty);
  });

  test('mentions 模式只在被提及時通知，但活動照發', () async {
    center.mode = NotifyModePref.mentions;
    center.follow('r1', roomName: '設計討論', myDisplayName: 'Bernie');
    feeds['r1']!.upsertAll([msg(1)]);
    await pump();
    feeds['r1']!.upsertAll([msg(2, content: '閒聊')]);
    await pump();
    expect(sent, isEmpty);
    expect(activity, ['r1']);
    feeds['r1']!.upsertAll([msg(3, mentions: ['Bernie'])]);
    await pump();
    expect(sent, hasLength(1));
    expect(sent.single.mentioned, isTrue);
  });

  test('off 模式完全不通知；正在看的房（前景）也抑制', () async {
    center.follow('r1', roomName: 'A');
    center.follow('r2', roomName: 'B');
    feeds['r1']!.upsertAll([msg(1)]);
    feeds['r2']!.upsertAll([msg(1)]);
    await pump();

    center.mode = NotifyModePref.off;
    feeds['r1']!.upsertAll([msg(2)]);
    await pump();
    expect(sent, isEmpty);

    center.mode = NotifyModePref.all;
    center.activeRoomId = 'r2';
    center.foreground = true;
    feeds['r2']!.upsertAll([msg(2)]);
    await pump();
    expect(sent, isEmpty, reason: '畫面本身就是通知');

    center.foreground = false; // 視窗失焦後同一個房要通知
    feeds['r2']!.upsertAll([msg(3)]);
    await pump();
    expect(sent, hasLength(1));
  });

  test('retainOnly 停止跟隨已移出的房間', () async {
    final unsubscribed = <String>[];
    final c2 = NotificationCenter(subscribe, unsubscribed.add, syncIdentity);
    c2.follow('r1', roomName: 'A');
    c2.follow('r2', roomName: 'B');
    c2.retainOnly({'r1'});
    expect(c2.followedRoomIds, {'r1'});
    expect(unsubscribed, ['r2']);
    c2.dispose();
  });

  test('follow 已有內容的暖 feed 以現況為基準（回訪不重播）', () async {
    final feed = subscribe('r1');
    feed.upsertAll([msg(1), msg(2)]);
    center.follow('r1', roomName: 'A');
    feeds['r1']!.upsertAll([msg(3)]);
    await pump();
    expect(sent, hasLength(1));
    expect(sent.single.body, isNot(contains('2 則')));
  });
}
