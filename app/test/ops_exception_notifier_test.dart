import 'package:chatroom_app/models/ops_exception.dart';
import 'package:chatroom_app/notifications/notification_center.dart';
import 'package:chatroom_app/notifications/ops_exception_notifier.dart';
import 'package:flutter_test/flutter_test.dart';

OpsException _e(String id, String kind, String createdAt,
        {String roomId = 'room-1'}) =>
    OpsException(
      id: id,
      kind: kind,
      reason: kind,
      severity: kind == 'stalled' ? 'warn' : 'error',
      roomId: roomId,
      roomName: '工作房',
      runId: 'run-$id',
      runKind: 'investigate',
      runRef: 'task-$id',
      runnerId: 'runner-1',
      detail: const {},
      createdAt: createdAt,
    );

void main() {
  late List<RoomNotification> sent;
  late List<OpsException> feed;
  late OpsExceptionNotifier notifier;

  setUp(() {
    sent = [];
    feed = [];
    notifier = OpsExceptionNotifier(
      fetch: () async => feed,
      show: sent.add,
    );
  });

  test('首批不通知：一開 App 就被昨天的事轟炸，該看的那則反而被忽略', () async {
    feed = [_e('a', 'timeout', '2026-09-18T10:00:00Z')];
    expect(await notifier.pollOnce(), 0);
    expect(sent, isEmpty);
    expect(notifier.watermark, '2026-09-18T10:00:00Z');
  });

  test('基準線之後：只投掉線與逾時，停滯不投', () async {
    feed = [_e('a', 'stalled', '2026-09-18T10:00:00Z')];
    await notifier.pollOnce();

    feed = [
      _e('c', 'runner_offline', '2026-09-18T12:00:00Z'),
      _e('b', 'stalled', '2026-09-18T11:00:00Z'),
      _e('a', 'stalled', '2026-09-18T10:00:00Z'),
    ];
    expect(await notifier.pollOnce(), 1);
    expect(sent.single.body, contains('已離線'));
    expect(sent.single.roomId, 'room-1');
    expect(sent.single.mentioned, isFalse);

    // 同一批再來一次不重投：輪詢每 30 秒一輪，重投等於每 30 秒響一次
    expect(await notifier.pollOnce(), 0);
    expect(sent, hasLength(1));
  });

  test('撈不到就這一輪不做事，且水位不動', () async {
    feed = [_e('a', 'timeout', '2026-09-18T10:00:00Z')];
    await notifier.pollOnce();
    final failing = OpsExceptionNotifier(
      fetch: () async => throw Exception('Hub 斷線'),
      show: sent.add,
    );
    expect(await failing.pollOnce(), 0);
    expect(sent, isEmpty);
    expect(failing.watermark, '');
  });
}
