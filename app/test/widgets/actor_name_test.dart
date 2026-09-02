import 'package:chatroom_app/models/board.dart';
import 'package:chatroom_app/widgets/actor_name.dart';
import 'package:flutter_test/flutter_test.dart';

/// Board 上的 actor 名稱與別名提示。
///
/// 規則來自艾斯維爾 #28 第 2 點：顯示名以最早進入 Board 者為準，其餘作為
/// 別名可查。提示存在的理由是「在別的房認識他的人看不懂板上這個名字」，
/// 所以**講不出出處的提示只完成了一半**。

BoardActorRef _actor({List<BoardAlias> aliases = const []}) => BoardActorRef(
  actorKey: 'claude-x',
  displayName: '開發Novia (UI)',
  actorKind: 'claude',
  aliases: aliases,
);

void main() {
  test('沒有別名就沒有提示，不掛一個空的 tooltip', () {
    // hover 上去什麼都不出現，比沒有 hover 更像壞了
    expect(actorAliasTooltip(_actor()), isNull);
  });

  test('查得到房名時講出處', () {
    final tip = actorAliasTooltip(
      _actor(aliases: const [BoardAlias(name: 'Novia', roomId: 'r1')]),
      roomNameOf: (id) => id == 'r1' ? '需求討論' : null,
    );
    expect(tip, contains('Novia'));
    expect(tip, contains('需求討論'));
  });

  test('房已解除或刪除時只講別名，不吐 uuid', () {
    // room_id 對使用者沒有意義。「他在 a3f9… 裡叫 Novia」等於沒講，
    // 而且看起來像資料壞了
    final tip = actorAliasTooltip(
      _actor(aliases: const [BoardAlias(name: 'Novia', roomId: 'r-gone')]),
      roomNameOf: (_) => null,
    );
    expect(tip, contains('Novia'));
    expect(tip, isNot(contains('r-gone')));
  });

  test('多個別名各自成行', () {
    final tip = actorAliasTooltip(
      _actor(aliases: const [
        BoardAlias(name: 'Novia', roomId: 'r1'),
        BoardAlias(name: '諾薇亞', roomId: 'r2'),
      ]),
      roomNameOf: (id) => id == 'r1' ? '需求討論' : '驗收',
    );
    expect(tip!.split('\n').where((l) => l.startsWith('·')).length, 2);
  });
}
