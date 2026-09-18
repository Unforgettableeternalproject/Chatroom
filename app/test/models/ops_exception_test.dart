import 'package:chatroom_app/models/ops_exception.dart';
import 'package:chatroom_app/state/ops_exceptions_providers.dart';
import 'package:flutter_test/flutter_test.dart';

/// 監控器的模型解析與分類。每一條都對應一個**安靜的失敗**：
/// - 分類讀錯：已經被殺掉的 run 被畫成「等一下自己會好」
/// - 通知條件讀錯：停滯每十分鐘推一次，然後真正該看的那則被忽略
/// - 未讀計數用總數：數字永遠不會歸零，跟沒有一樣
Map<String, dynamic> _json({
  String id = 'e1',
  String kind = 'stalled',
  String reason = 'stalled',
  String severity = 'warn',
  Map<String, dynamic> detail = const {},
  String createdAt = '2026-09-18T10:00:00+00:00',
}) =>
    {
      'id': id,
      'kind': kind,
      'reason': reason,
      'severity': severity,
      'room_id': 'room-1',
      'room_name': '工作房',
      'run_id': 'run-1',
      'run_kind': 'investigate',
      'run_ref': 'task-1',
      'runner_id': 'runner-1',
      'detail': detail,
      'created_at': createdAt,
    };

void main() {
  test('解析：缺欄位退成空字串，不是 null 也不是丟例外', () {
    final e = OpsException.fromJson({'id': 'e1', 'kind': 'timeout'});
    expect(e.runRef, '');
    expect(e.severity, 'warn');
    expect(e.detail, isEmpty);
  });

  test('停滯的秒數來自 detail，沒講就不編一個數字出來', () {
    final withSecs =
        OpsException.fromJson(_json(detail: {'stalled_seconds': 620}));
    expect(withSecs.title, contains('620 秒'));
    final without = OpsException.fromJson(_json());
    expect(without.title, isNot(contains('秒')));
  });

  test('逾時的兩條路分得開：硬牆與收尾逾時不是同一件事', () {
    final wall = OpsException.fromJson(
        _json(kind: 'timeout', reason: 'wall_clock', severity: 'error'));
    final soft = OpsException.fromJson(
        _json(kind: 'timeout', reason: 'soft_stop_timeout', severity: 'error'));
    expect(wall.title, contains('逾時'));
    expect(soft.title, contains('收尾逾時'));
    expect(wall.isError && soft.isError, isTrue);
  });

  test('執行器掉線用 label，沒有 run 也要講得出是哪一台', () {
    final e = OpsException.fromJson({
      'id': 'v1',
      'kind': 'runner_offline',
      'reason': 'runner_offline',
      'severity': 'error',
      'room_id': 'room-1',
      'room_name': '工作房',
      'run_id': '',
      'runner_id': 'runner-1',
      'detail': {'label': 'esvel-pc'},
      'created_at': '2026-09-18T10:00:00+00:00',
    });
    expect(e.title, '執行器 esvel-pc 已離線');
    expect(e.runId, '');
  });

  test('只有掉線與逾時推通知；停滯／額度受限／恢復只進面板', () {
    bool notifiable(String kind) =>
        OpsException.fromJson(_json(kind: kind)).notifiable;
    expect(notifiable('runner_offline'), isTrue);
    expect(notifiable('timeout'), isTrue);
    expect(notifiable('stalled'), isFalse);
    expect(notifiable('rate_limited'), isFalse);
    expect(notifiable('resumed'), isFalse);
    expect(notifiable('runner_online'), isFalse);
  });

  test('分頁：空清單時游標原樣回來，不退回空字串', () {
    final page = OpsExceptionPage.fromJson(
        {'exceptions': const [], 'next_since': 'e1'});
    expect(page.exceptions, isEmpty);
    expect(page.nextSince, 'e1');
  });

  test('未讀計數＝比水位新的那幾筆', () {
    final list = [
      OpsException.fromJson(_json(id: 'c', createdAt: '2026-09-18T12:00:00Z')),
      OpsException.fromJson(_json(id: 'b', createdAt: '2026-09-18T11:00:00Z')),
      OpsException.fromJson(_json(id: 'a', createdAt: '2026-09-18T10:00:00Z')),
    ];
    expect(unreadExceptionCount(list, ''), 3);
    expect(unreadExceptionCount(list, '2026-09-18T11:00:00Z'), 1);
    expect(unreadExceptionCount(list, '2026-09-18T12:00:00Z'), 0);
  });
}
