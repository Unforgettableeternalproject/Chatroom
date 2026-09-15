import 'package:chatroom_app/models/room.dart';
import 'package:flutter_test/flutter_test.dart';

/// 對話鎖定：private 的房 Hub 只會列給有份的人，App 端只負責認得出它。
///
/// 預設值是這裡最重要的一件事：舊版 Hub 不回 `visibility`，那時一律當成
/// 公開——那正是舊 Hub 的行為。預設成 private 會讓升級前的所有房間莫名
/// 掛上鎖頭。
void main() {
  Map<String, dynamic> json(Map<String, dynamic> extra) => {
        'id': 'r1',
        'name': '房',
        'topic': '',
        'status': 'active',
        'created_at': '2026-08-30T00:00:00Z',
        ...extra,
      };

  test('沒有 visibility 欄位時視為公開（舊版 Hub）', () {
    final room = Room.fromJson(json({}));
    expect(room.visibility, 'public');
    expect(room.isPrivate, isFalse);
  });

  test('private 會被認出來', () {
    final room = Room.fromJson(json({'visibility': 'private'}));
    expect(room.isPrivate, isTrue);
  });

  test('顯式 public 也是公開', () {
    expect(Room.fromJson(json({'visibility': 'public'})).isPrivate, isFalse);
  });

  test('copyWith 不指定時保留鎖定狀態', () {
    final room = Room.fromJson(json({'visibility': 'private'}));
    expect(room.copyWith(status: 'archived').isPrivate, isTrue);
    expect(room.copyWith(visibility: 'public').isPrivate, isFalse);
  });
}
