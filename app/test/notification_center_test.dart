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
    );

void main() {
  late Map<String, RoomFeed> feeds;
  late NotificationCenter center;
  late List<RoomNotification> sent;
  late List<String> activity;

  final subscribedIds = <String, String?>{};
  RoomFeed subscribe(String roomId, {String? participantId}) {
    if (participantId != null) subscribedIds[roomId] = participantId;
    return feeds.putIfAbsent(roomId, () => RoomFeed(roomId));
  }

  setUp(() {
    feeds = {};
    subscribedIds.clear();
    sent = [];
    activity = [];
    center = NotificationCenter(subscribe, (_) {});
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

  test('先跟房、之後才拿到身分：要補送訂閱', () async {
    center.follow('r1', roomName: 'A');
    expect(subscribedIds['r1'], isNull);
    // join 完成後帶著身分再 follow 一次（bootstrap 的正常時序）
    center.follow('r1', roomName: 'A', myParticipantId: 'p1');
    expect(subscribedIds['r1'], 'p1',
        reason: '不補送的話 server 那條訂閱永遠是匿名的');
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
    final c2 = NotificationCenter(subscribe, unsubscribed.add);
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
