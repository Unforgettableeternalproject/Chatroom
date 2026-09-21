import 'package:chatroom_app/models/room.dart';
import 'package:flutter_test/flutter_test.dart';

/// 「同一專案一次只跑一筆」（`single_writer`）。
///
/// 🔴 **缺鍵一律 true。** 舊 Hub 不回這個欄位，而它的行為一直都是鎖著的。
/// 猜 false 會讓畫面說出「多筆派工會同時改同一個 repo」，而 Hub 其實還是
/// 一筆一筆跑——那句話是假的，而且會讓人以為自己可以同時派兩筆。
void main() {
  Map<String, dynamic> base(Map<String, dynamic> extra) => {
        'id': 'r1',
        'name': '遠端派工',
        'kind': 'ops',
        'created_at': '2026-09-21T00:00:00+00:00',
        ...extra,
      };

  test('舊 Hub 沒有這個欄位：當成鎖著的', () {
    expect(Room.fromJson(base(const {})).singleWriter, isTrue);
  });

  test('Hub 說關了就是關了', () {
    expect(
        Room.fromJson(base(const {'single_writer': false})).singleWriter,
        isFalse);
    expect(
        Room.fromJson(base(const {'single_writer': true})).singleWriter,
        isTrue);
  });

  test('copyWith 不會把關掉的狀態弄回 true——列表更新一次就悄悄鎖回去的話，'
      '畫面上那顆開關會自己跳回來', () {
    final room = Room.fromJson(base(const {'single_writer': false}));
    expect(room.copyWith(memberCount: 3).singleWriter, isFalse);
    expect(room.copyWith(singleWriter: true).singleWriter, isTrue);
  });
}
