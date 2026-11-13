import 'package:chatroom_app/models/board.dart';
import 'package:chatroom_app/models/board_task_filter.dart';
import 'package:flutter_test/flutter_test.dart';

BoardTask _t(String id,
        {String title = '',
        String desc = '',
        String status = 'todo',
        Map<String, dynamic>? extra}) =>
    BoardTask.fromJson({
      'id': id,
      'checklist_id': 'c1',
      'title': title.isEmpty ? '卡 $id' : title,
      'description': desc,
      'status': status,
      ...?extra,
    });

Map<String, dynamic> get _dep => {
      'depends_on': [
        {'id': 'x', 'title': 'x', 'status': 'todo', 'met': false}
      ]
    };

void main() {
  final tasks = [
    _t('a', title: 'Login 頁面', status: 'todo'),
    _t('b',
        desc: '修 login 的 bug',
        status: 'in_progress',
        extra: {'claim_state': 'held'}),
    _t('c', status: 'done', extra: _dep),
    _t('d', status: 'cancelled', extra: {'claim_state': 'orphaned'}),
  ];
  List<String> ids(BoardTaskFilter f) =>
      f.apply(tasks).map((t) => t.id).toList();

  test('沒有條件：全部通過、isActive 為 false', () {
    const f = BoardTaskFilter();
    expect(f.isActive, isFalse);
    expect(ids(f), ['a', 'b', 'c', 'd']);
  });

  test('關鍵字比對標題與內容，不分大小寫', () {
    expect(ids(const BoardTaskFilter(keyword: 'LOGIN')), ['a', 'b']);
    expect(ids(const BoardTaskFilter(keyword: '  bug ')), ['b']);
  });

  test('卡片狀態', () {
    expect(ids(const BoardTaskFilter(status: 'done')), ['c']);
    expect(ids(const BoardTaskFilter(status: 'blocked')), isEmpty);
  });

  test('是否有依賴只看自己的 dependsOn', () {
    expect(ids(const BoardTaskFilter(dependency: TriFilter.yes)), ['c']);
    expect(
        ids(const BoardTaskFilter(dependency: TriFilter.no)), ['a', 'b', 'd']);
  });

  test('是否已認領：持有中才算，孤兒卡算未認領', () {
    expect(ids(const BoardTaskFilter(claimed: TriFilter.yes)), ['b']);
    expect(ids(const BoardTaskFilter(claimed: TriFilter.no)), ['a', 'c', 'd']);
  });

  test('條件取交集', () {
    const f = BoardTaskFilter(
        keyword: 'login', claimed: TriFilter.yes, status: 'in_progress');
    expect(ids(f), ['b']);
  });
}
