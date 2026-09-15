import 'package:chatroom_app/core/errors/api_exception.dart';
import 'package:flutter_test/flutter_test.dart';

/// 板的成員資格 403 **不可以**走 ParticipantInvalidException。
///
/// 那個型別會觸發自動 re-join，而**重新加入聊天室一百次也不會讓你出現在
/// 板的成員列上**。板的成員資格與房內身分是兩件事（艾斯維爾裁決 A+），
/// 混在一起會產生一個永遠不會成功、而且看起來像卡住的迴圈。
void main() {
  test('是自己的型別，不是身分失效', () {
    const e = BoardAccessException('not_board_member', '你還不是這塊板的成員');
    expect(e, isNot(isA<ParticipantInvalidException>()));
  });

  test('帶得出 board_id 與 board_name', () {
    // 被擋下的回應裡，這兩個是唯一還拿得到的東西——落地畫面要靠它們
    // 講出「這間房掛著哪塊板」，不必再打一次必然再被擋的 API
    const e = BoardAccessException('not_board_member', '擋下了', {
      'board_id': 'b1',
      'board_name': 'Board V2',
    });
    expect(e.boardId, 'b1');
    expect(e.boardName, 'Board V2');
  });

  test('Hub 沒帶那兩個值時回空字串，不是丟例外', () {
    // 落地畫面要能在沒有板名時退成一句通用的話，
    // 而不是在一個「被擋下」的畫面上再炸一次
    const e = BoardAccessException('not_board_owner', '只有 owner 可以');
    expect(e.boardId, '');
    expect(e.boardName, '');
  });
}
