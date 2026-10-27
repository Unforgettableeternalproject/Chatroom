import 'package:chatroom_app/models/room.dart';
import 'package:flutter_test/flutter_test.dart';

/// 自動封存開關（`auto_archive`）。
///
/// 缺鍵一律 true：舊 Hub 不回這個欄位，而它一直都會自動封存。
void main() {
  Map<String, dynamic> base(Map<String, dynamic> extra) => {
        'id': 'r1',
        'name': '房間',
        'created_at': '2026-10-27T00:00:00+00:00',
        ...extra,
      };

  test('舊 Hub 沒有這個欄位：當成開啟', () {
    expect(Room.fromJson(base(const {})).autoArchive, isTrue);
  });

  test('Hub 說關了就是關了', () {
    expect(Room.fromJson(base(const {'auto_archive': false})).autoArchive,
        isFalse);
    expect(Room.fromJson(base(const {'auto_archive': true})).autoArchive,
        isTrue);
  });

  test('copyWith 不會把關掉的狀態弄回 true', () {
    final room = Room.fromJson(base(const {'auto_archive': false}));
    expect(room.copyWith(memberCount: 3).autoArchive, isFalse);
    expect(room.copyWith(autoArchive: true).autoArchive, isTrue);
  });
}
