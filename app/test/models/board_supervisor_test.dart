import 'package:chatroom_app/models/board.dart';
import 'package:flutter_test/flutter_test.dart';

/// Supervisor 是 **per-room** 的（艾斯維爾 2026-09-03：「他不再是 per board
/// 而是 per room」）。板軸畫面因此沒有「這塊板的 supervisor」這種東西可以
/// 顯示，只有**掛接房的彙整**。
///
/// 🔴 這條測試守的是一個曾經靜默壞掉的東西：`BoardSnapshot.supervisor`
/// （頂層那個）讀的是 server 的 `board.supervisor_*`，而那幾欄**恆空**
/// （2026-09-05 除錯端查 8787 生產庫：board 層級 0 筆）。
/// 於是 `supervisor_panel` 的 `isSupervisor` 恆 false ⇒ **只有 owner 按得到
/// 「發指令」，而 supervisor 其實送得出去**（server 的第二問走掛接房）。
///
/// 畫面上只是少一顆按鈕，沒有錯誤、沒有紅字——該給的按鈕沒給，是最不像
/// 壞掉的那種壞掉。
BoardSnapshot _snap(List<AttachedRoom> rooms) => BoardSnapshot(
      boardId: 'b1',
      attachedRooms: {for (final r in rooms) r.id: r},
    );

AttachedRoom _room(
  String id, {
  String name = '',
  String? supervisorKey,
  bool departed = false,
  bool detached = false,
}) =>
    AttachedRoom(
      id: id,
      name: name.isEmpty ? id : name,
      detached: detached,
      supervisor: supervisorKey == null
          ? null
          : BoardActorRef(actorKey: supervisorKey, displayName: supervisorKey),
      supervisorDeparted: departed,
    );

void main() {
  group('我是不是某間掛接房的 supervisor', () {
    test('🔴 是的話要算得出來——這是「發指令」那顆按鈕的唯一依據', () {
      final s = _snap([
        _room('r1', supervisorKey: 'someone'),
        _room('r2', supervisorKey: 'me'),
      ]);
      expect(s.supervisesAnyRoom('me'), isTrue);
    });

    test('都不是的時候是 false', () {
      final s = _snap([_room('r1', supervisorKey: 'someone')]);
      expect(s.supervisesAnyRoom('me'), isFalse);
    });

    test('🔴 已經解除掛接的房不算——那塊板與那間房已經沒有關係了', () {
      final s = _snap([_room('r1', supervisorKey: 'me', detached: true)]);
      expect(s.supervisesAnyRoom('me'), isFalse);
    });

    test('🔴 `departed` 仍然算', () {
      // departed 是 presence（他離開過那間房），不是卸任。人回來了、旗標
      // 還沒清的那一刻若不給按，就是把權限判給了一個時間差。真正的守門在
      // server，UI 這裡只決定畫不畫——**該給不給比畫了被拒更貴**
      final s = _snap([_room('r1', supervisorKey: 'me', departed: true)]);
      expect(s.supervisesAnyRoom('me'), isTrue);
    });

    test('空字串不算任何人——沒有身分的時候不可以碰巧變成 supervisor', () {
      final s = _snap([_room('r1', supervisorKey: null)]);
      expect(s.supervisesAnyRoom(''), isFalse);
    });
  });

  group('板軸要顯示的彙整', () {
    test('每間掛接房各一筆，帶得出來源房', () {
      final s = _snap([
        _room('r1', name: '09/05 開發', supervisorKey: 'a'),
        _room('r2', name: '09/02 開發', supervisorKey: 'b', departed: true),
      ]);
      final sup = s.roomSupervisors;
      expect(sup, hasLength(2));
      expect(sup.first.roomName, '09/05 開發');
      expect(sup.first.actor.displayName, 'a');
      expect(sup.last.departed, isTrue, reason: '已離開要畫得出來，不是當成沒人');
    });

    test('🔴 沒指派 supervisor 的房不列——空白就是空白，不要編一個出來', () {
      final s = _snap([_room('r1'), _room('r2', supervisorKey: 'a')]);
      expect(s.roomSupervisors, hasLength(1));
    });

    test('🔴 沒掛任何房＝正確的空白，不是壞掉', () {
      expect(_snap(const []).roomSupervisors, isEmpty);
    });

    test('解除掛接的房不列', () {
      final s = _snap([_room('r1', supervisorKey: 'a', detached: true)]);
      expect(s.roomSupervisors, isEmpty);
    });
  });
}
