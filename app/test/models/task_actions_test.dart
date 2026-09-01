import 'package:chatroom_app/models/board.dart';
import 'package:flutter_test/flutter_test.dart';

/// 抽屜底部要出哪幾顆按鈕。
///
/// 舊版的判斷是「還沒收尾就全部出」，於是畫出四顆非法按鈕，按下去只會拿
/// 409——而當時連 409 都看不見。更嚴重的是**少了一顆**：全 App 沒有任何
/// 路徑能把 `todo` 推成 `in_progress`，而那是 Hub 通往 `done` 的唯一樞紐。
/// 使用者完全無法把一張卡做完。
///
/// 所以這裡驗的是兩件事：**不該出的沒出**，以及**該出的有出**。後者才是
/// 那條阻斷缺陷，只驗前者的話它會原封不動地留著。
Set<String> _targets(String status) =>
    taskActionsFor(status).map((a) => a.target).toSet();

void main() {
  group('按鈕集合＝Hub 允許的轉移', () {
    for (final status in kTaskTransitions.keys) {
      test('$status 出的每一顆都是合法轉移，而且一顆不少', () {
        expect(_targets(status), kTaskTransitions[status]);
      });
    }
  });

  group('那四顆非法按鈕', () {
    test('todo 不給「標記完成」——中間還隔著 in_progress', () {
      expect(_targets('todo').contains('done'), isFalse);
    });

    test('todo 不給「標記卡住」', () {
      expect(_targets('todo').contains('blocked'), isFalse);
    });

    test('blocked 不給「標記完成」——要先解除卡住', () {
      expect(_targets('blocked').contains('done'), isFalse);
    });

    test('done 的「重新開啟」送 in_progress，不是 todo', () {
      expect(_targets('done'), {'in_progress'});
    });
  });

  group('🔴 少掉的那一格', () {
    test('todo 有「開始」，否則沒有人能把卡做完', () {
      final start = taskActionsFor('todo').where((a) => a.target == 'in_progress');
      expect(start, hasLength(1));
      expect(start.first.label, '開始');
    });

    test('cancelled 可以復原', () {
      expect(_targets('cancelled'), {'todo'});
    });
  });

  group('標籤依來源狀態而定', () {
    String labelFor(String from, String target) => taskActionsFor(from)
        .firstWhere((a) => a.target == target)
        .label;

    test('推去 in_progress 的三種語境是三句不同的話', () {
      expect(labelFor('todo', 'in_progress'), '開始');
      expect(labelFor('blocked', 'in_progress'), '解除卡住');
      expect(labelFor('done', 'in_progress'), '重新開啟');
    });
  });

  group('Hub 的 allowed 蓋過本機副本', () {
    test('副本漂移時以 Hub 的說法為準', () {
      // 假設 Hub 收緊了 in_progress，只剩下取消
      final items = taskActionsFor('in_progress', allowed: {'cancelled'});
      expect(items.map((a) => a.target), ['cancelled']);
    });

    test('allowed 是空的就一顆都不出，不要留按不動的按鈕', () {
      expect(taskActionsFor('todo', allowed: <String>{}), isEmpty);
    });
  });

  group('取消要跟其他動作分開', () {
    test('取消靠右擺，不然會被誤按', () {
      final cancel = taskActionsFor('in_progress')
          .firstWhere((a) => a.target == 'cancelled');
      expect(cancel.trailing, isTrue);
      expect(cancel.danger, isTrue);
    });
  });
}
