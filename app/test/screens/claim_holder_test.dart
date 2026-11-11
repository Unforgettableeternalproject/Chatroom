import 'package:chatroom_app/core/errors/api_exception.dart';
import 'package:chatroom_app/screens/board/board_screen.dart';
import 'package:flutter_test/flutter_test.dart';

/// 409 `task_already_claimed` 的訊息內文沒有「」——名字只在 detail.claim_name。
void main() {
  const fallback = '別人';

  test('🔴 取 detail.claim_name，含空白與括號的名字原樣', () {
    const e = ConflictException(
      'task_already_claimed',
      '這張卡已經有人在做，或它已經完成／取消了',
      detail: {'claim_name': 'Core 開發 (工具層)', 'held_by_same_name': false},
    );
    expect(claimHolderFrom(e, fallback), 'Core 開發 (工具層)');
  });

  test('claim_name 為空或缺 → 泛稱', () {
    expect(
      claimHolderFrom(
        const ConflictException('task_already_claimed', 'x',
            detail: {'claim_name': ''}),
        fallback,
      ),
      fallback,
    );
    expect(
      claimHolderFrom(
          const ConflictException('task_already_claimed', 'x'), fallback),
      fallback,
    );
  });

  test('不是 ApiException → 泛稱', () {
    expect(claimHolderFrom(StateError('「某人」'), fallback), fallback);
  });
}
