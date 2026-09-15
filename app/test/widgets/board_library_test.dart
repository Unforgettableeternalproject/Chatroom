import 'package:chatroom_app/core/errors/api_exception.dart';
import 'package:chatroom_app/state/board_providers.dart';
import 'package:flutter_test/flutter_test.dart';

/// Board Library 的錯誤分流。
///
/// 遷移期間「Hub 還沒開這個端點」與「端點壞了」都會走進錯誤分支，但使用者
/// 該有的反應相反：一個是等升級，一個是去修。畫面若都寫「載入失敗」，
/// 看的人只能猜——而**空清單與端點不存在在畫面上長得一模一樣**，
/// 那正是最難查的一種。
void main() {
  test('404 是「Hub 還沒有 Board Library」，不是壞掉', () {
    expect(boardLibraryUnavailable(const NotFoundException('board')), isTrue);
  });

  test('其他 API 錯誤是真的壞了，要走一般錯誤畫面', () {
    expect(boardLibraryUnavailable(const AuthException()), isFalse);
    expect(boardLibraryUnavailable(ServerException(500)), isFalse);
  });

  test('非 ApiException 一律當真錯誤，不可誤判成「還沒就緒」', () {
    // 誤判的方向很重要：把真的故障說成「等升級就好」，
    // 會讓一個該被修的問題永遠沒有人去修
    expect(boardLibraryUnavailable(Exception('boom')), isFalse);
  });
}
