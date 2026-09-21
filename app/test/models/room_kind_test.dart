import 'package:chatroom_app/models/room.dart';
import 'package:flutter_test/flutter_test.dart';

/// `room.kind`：工作房與一般對話。
///
/// 🔴 **缺欄位一律 `chat`。** 舊 Hub 不回 `kind`，而那時所有房間的行為就是
/// chat（會自動封存、任何憑證都建得了）。猜成 ops 的話，升級前的每一間房都
/// 會在畫面上掛著「不會自動封存」與一個派工入口，而兩句話都是假的。
void main() {
  test('Hub 回 ops 就是工作房', () {
    final room = Room.fromJson(const {
      'id': 'r1',
      'name': '遠端派工',
      'kind': 'ops',
      'created_at': '2026-09-16T00:00:00+00:00',
    });
    expect(room.kind, 'ops');
    expect(room.isOps, isTrue);
  });

  test('沒有 kind 的舊 Hub：當成 chat，不是空字串', () {
    final room = Room.fromJson(const {
      'id': 'r1',
      'name': '一般房',
      'created_at': '2026-09-16T00:00:00+00:00',
    });
    expect(room.kind, 'chat');
    expect(room.isOps, isFalse);
  });

  test('copyWith 不會把 kind 弄丟——列表更新一次就不再是工作房的話，'
      '入口會在使用者眼前消失', () {
    final room = Room.fromJson(const {
      'id': 'r1',
      'name': '遠端派工',
      'kind': 'ops',
      'created_at': '2026-09-16T00:00:00+00:00',
    });
    expect(room.copyWith(memberCount: 3).isOps, isTrue);
  });
}
