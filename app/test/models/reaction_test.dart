import 'package:chatroom_app/models/message.dart';
import 'package:chatroom_app/models/reaction.dart';
import 'package:chatroom_app/models/ws_event.dart';
import 'package:chatroom_app/state/reaction_actions.dart';
import 'package:chatroom_app/ws/room_feed.dart';
import 'package:chatroom_app/ws/ws_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

const thumb = '\u{1F44D}';
const heart = '❤️';

Message _msg({List<ReactionSummary> reactions = const []}) => Message(
      id: 'm1',
      seq: 3,
      updateSeq: 0,
      kind: 'chat',
      content: 'hi',
      createdAt: '2026-10-27T00:00:00+00:00',
      reactions: reactions,
    );

ReactionSummary _r(String e, int n, {bool mine = false, List<String>? names}) =>
    ReactionSummary(
        emoji: e, count: n, mine: mine, names: names ?? List.filled(n, 'x'));

void main() {
  test('Message.fromJson 解析 reactions，舊 Hub 沒欄位時為空', () {
    final base = {
      'id': 'm1',
      'seq': 1,
      'created_at': 't',
    };
    expect(Message.fromJson(base).reactions, isEmpty);
    final m = Message.fromJson({
      ...base,
      'reactions': [
        {'emoji': thumb, 'count': 2, 'mine': true, 'names': ['A', 'B']},
      ],
    });
    expect(m.reactions.single.emoji, thumb);
    expect(m.reactions.single.count, 2);
    expect(m.reactions.single.mine, isTrue);
    expect(m.reactions.single.names, ['A', 'B']);
  });

  test('Reactor.fromJson', () {
    final r = Reactor.fromJson({
      'participant_id': 'p1',
      'name': 'Bot',
      'role': 'agent',
      'kind': 'claude',
      'emoji': thumb,
      'mine': false,
    });
    expect(r.isAgent, isTrue);
    expect(r.kind, 'claude');
  });

  test('WS reaction 事件解碼', () {
    final e = WsProtocol.decode('{"type":"reaction","room_id":"r","message_id":'
        '"m1","reactions":[{"emoji":"$thumb","count":1,"mine":false,'
        '"names":["Bob"]}]}');
    expect(e, isA<WsReactionEvent>());
    e as WsReactionEvent;
    expect(e.messageId, 'm1');
    expect(e.reactions.single.names, ['Bob']);
  });

  group('reactionsAfter（替換語意）', () {
    test('沒有表情時加入', () {
      final out = reactionsAfter(const [], toEmoji: thumb, myName: 'Me');
      expect(out, [_r(thumb, 1, mine: true, names: ['Me'])]);
    });

    test('換成別的表情：舊的少一個、新的多一個，只剩新的是我的', () {
      final cur = [
        _r(thumb, 2, mine: true, names: ['Me', 'Bob']),
        _r(heart, 1, names: ['Amy']),
      ];
      final out = reactionsAfter(cur, toEmoji: heart, myName: 'Me');
      expect(out, [
        _r(thumb, 1, names: ['Bob']),
        _r(heart, 2, mine: true, names: ['Amy', 'Me']),
      ]);
    });

    test('取消：最後一個人取消時 chip 消失', () {
      final cur = [_r(thumb, 1, mine: true, names: ['Me'])];
      expect(reactionsAfter(cur, toEmoji: null, myName: 'Me'), isEmpty);
    });
  });

  group('RoomFeed', () {
    test('setReactions 只換彙總，不推進 cursor', () {
      final feed = RoomFeed('r')..upsertAll([_msg()]);
      final cursor = feed.cursor;
      var notified = 0;
      feed.changes.listen((_) => notified++);
      feed.setReactions('m1', [_r(thumb, 1)]);
      expect(feed.byId('m1')!.reactions.single.emoji, thumb);
      expect(feed.cursor, cursor);
    });

    test('replaceReactions 校正：沒出現的視為沒有表情', () {
      final feed = RoomFeed('r')..upsertAll([_msg(reactions: [_r(thumb, 1)])]);
      feed.replaceReactions({}, 0);
      expect(feed.byId('m1')!.reactions, isEmpty);
    });
  });

  group('reactOptimistic', () {
    test('立即反映，成功後以 Hub 回傳為準', () async {
      final feed = RoomFeed('r')..upsertAll([_msg()]);
      var sawOptimistic = false;
      final ok = await reactOptimistic(
        feed: feed,
        messageId: 'm1',
        fallbackBefore: const [],
        emoji: thumb,
        myName: 'Me',
        send: (cancel) async {
          sawOptimistic = feed.byId('m1')!.reactions.single.mine;
          expect(cancel, isFalse);
          return [_r(thumb, 3, mine: true)];
        },
      );
      expect(ok, isTrue);
      expect(sawOptimistic, isTrue, reason: '送出前畫面就該已經更新');
      expect(feed.byId('m1')!.reactions.single.count, 3);
    });

    test('失敗：回滾到原本的彙總', () async {
      final original = [_r(heart, 1, names: ['Amy'])];
      final feed = RoomFeed('r')..upsertAll([_msg(reactions: original)]);
      final ok = await reactOptimistic(
        feed: feed,
        messageId: 'm1',
        fallbackBefore: original,
        emoji: thumb,
        myName: 'Me',
        send: (_) async => throw Exception('boom'),
      );
      expect(ok, isFalse);
      expect(feed.byId('m1')!.reactions, original);
    });

    test('選到自己目前那個＝取消（cancel=true）', () async {
      final feed = RoomFeed('r')
        ..upsertAll([
          _msg(reactions: [_r(thumb, 1, mine: true, names: ['Me'])])
        ]);
      bool? gotCancel;
      await reactOptimistic(
        feed: feed,
        messageId: 'm1',
        fallbackBefore: const [],
        emoji: thumb,
        myName: 'Me',
        send: (cancel) async {
          gotCancel = cancel;
          expect(feed.byId('m1')!.reactions, isEmpty);
          return const [];
        },
      );
      expect(gotCancel, isTrue);
    });
  });
}
