import 'package:chatroom_app/models/board.dart';
import 'package:flutter_test/flutter_test.dart';

/// 主持人模式下的 Board Library：**看得到別人的私人板，就要說得出是誰的**
/// （Hub `8bdb2d2` 補的 `owner_actor_key` / `owner_display_name`）。
///
/// 🔴 少了「誰的」那一列，畫面上是一排標著「私人」但不知道屬於誰的板——
/// 而主持人模式存在的理由正是要看得到別人的東西。「私人」只講了一半：
/// 它說這塊板不公開，沒說**不公開給誰以外的人**。
BoardSummary _b(Map<String, dynamic> json) => BoardSummary.fromJson({
      'id': 'b1',
      'name': '某塊板',
      ...json,
    });

void main() {
  test('owner 欄位讀得到', () {
    final b = _b({
      'owner_actor_key': 'claude-abc',
      'owner_display_name': '開發Novia (Hub)',
    });
    expect(b.ownerDisplayName, '開發Novia (Hub)');
    expect(b.ownerActorKey, 'claude-abc');
  });

  test('🔴 「是不是別人的」用 my_role 判，不用 owner 比對', () {
    // ⚠️ UI 手上**沒有**「我是誰」的 actor_key——那是 Hub 不外流的
    // session_key。拿別的東西拼一個出來比對必然漂移，而漂移的結果是
    // 把自己的板標成別人的（或反過來），兩種都不會報錯。
    // Hub 已經算好 `my_role` 了：空字串＝我在這塊板上沒有角色。
    expect(_b({'my_role': 'owner'}).notMine, isFalse);
    expect(_b({'my_role': 'editor'}).notMine, isFalse);
    expect(_b({'my_role': 'viewer'}).notMine, isFalse);
    expect(_b({}).notMine, isTrue);
  });

  test('viewer 是「有份但只能看」，不是別人的板', () {
    // 被邀請進來的人角色是 viewer——那塊板在他的清單裡本來就該出現，
    // 標成「別人的板」會讓他以為自己是誤看到主持人視角
    expect(_b({'my_role': 'viewer', 'owner_display_name': '某人'}).notMine,
        isFalse);
  });

  test('舊 Hub 不回這兩欄時是空字串，不是 null 崩潰', () {
    final b = _b({'my_role': 'owner'});
    expect(b.ownerActorKey, '');
    expect(b.ownerDisplayName, '');
  });

  test('名字查不到但確實是別人的——仍要標得出來', () {
    // Hub 的 `_actor_display_name` 查不到會回空字串。這時 UI 退到
    // 「別人的板」，**不是留白**：留白會被讀成自己的板
    final b = _b({'owner_actor_key': 'claude-gone', 'owner_display_name': ''});
    expect(b.notMine, isTrue);
    expect(b.ownerDisplayName, isEmpty);
  });
}
