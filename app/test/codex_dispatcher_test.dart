import 'dart:convert';
import 'dart:io';

import 'package:chatroom_app/models/message.dart';
import 'package:chatroom_app/notifications/codex_dispatcher.dart';
import 'package:chatroom_app/notifications/notification_center.dart';
import 'package:flutter_test/flutter_test.dart';

Message msg(int seq,
        {String? senderId = 'p-claude',
        String sender = 'Novia',
        String content = 'hi'}) =>
    Message(
      id: 'm$seq',
      seq: seq,
      updateSeq: 0,
      kind: 'chat',
      content: content,
      createdAt: '',
      senderId: senderId,
      senderName: sender,
    );

void main() {
  late List<List<String>> runs;
  late Directory codexHome;

  CodexDispatcher make({Map<String, String> kinds = const {}}) {
    final d = CodexDispatcher(
      (_) async => kinds,
      runProcess: (argv) async {
        runs.add(argv);
        return true;
      },
      codexArgvResolver: () => ['codex-bin'],
      codexHome: codexHome.path,
    );
    d.enabled = true;
    d.threadOverride = 'thread-x';
    return d;
  }

  setUp(() {
    runs = [];
    codexHome = Directory.systemTemp.createTempSync('codex-home-');
  });

  tearDown(() => codexHome.deleteSync(recursive: true));

  RoomFreshBatch batch(List<Message> msgs) =>
      RoomFreshBatch(roomId: 'r1', roomName: '設計討論', messages: msgs);

  test('轉送最新訊息摘要，thread 與內容經 argv 傳遞（不經 shell）', () async {
    final d = make(kinds: {'p-claude': 'claude'});
    await d.handle(batch([msg(1), msg(2, content: '最後 "一句" & <b>')]));
    expect(runs, hasLength(1));
    final argv = runs.single;
    expect(argv[argv.indexOf('--thread') + 1], 'thread-x');
    final text = argv[argv.indexOf('--message') + 1];
    expect(text, startsWith('[chatroom 通知] '));
    final payload =
        jsonDecode(text.substring('[chatroom 通知] '.length)) as Map;
    expect(payload['count'], 2);
    expect(payload['latest']['content'], '最後 "一句" & <b>');
  });

  test('Codex 自己的訊息不轉送（防止被自己的發言循環喚醒）', () async {
    final d = make(kinds: {'p-codex': 'codex', 'p-claude': 'claude'});
    await d.handle(batch([msg(1, senderId: 'p-codex', sender: 'Codex-Sol')]));
    expect(runs, isEmpty);
    // 混批：只剩非 codex 的部分照送
    await d.handle(batch([
      msg(2, senderId: 'p-codex', sender: 'Codex-Sol'),
      msg(3, senderId: 'p-claude'),
    ]));
    expect(runs, hasLength(1));
  });

  test('未啟用時完全不動作', () async {
    final d = make();
    d.enabled = false;
    await d.handle(batch([msg(1)]));
    expect(runs, isEmpty);
  });

  test('threadOverride 留空時抓最新的 lock 檔當目標', () async {
    final locks = Directory('${codexHome.path}/thread-writer-locks')
      ..createSync(recursive: true);
    File('${locks.path}/old-thread.lock').writeAsStringSync('');
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    File('${locks.path}/new-thread.lock').writeAsStringSync('');
    final d = make(kinds: {'p-claude': 'claude'});
    d.threadOverride = '';
    await d.handle(batch([msg(1)]));
    expect(runs, hasLength(1));
    final argv = runs.single;
    expect(argv[argv.indexOf('--thread') + 1], 'new-thread');
  });

  test('找不到任何 Codex session 時安靜略過', () async {
    final d = make(kinds: {'p-claude': 'claude'});
    d.threadOverride = '';
    await d.handle(batch([msg(1)]));
    expect(runs, isEmpty);
  });
}
