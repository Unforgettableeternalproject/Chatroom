import 'package:chatroom_app/widgets/markdown_body.dart';
import 'package:flutter_test/flutter_test.dart';

/// 群組 mention（`@agents` / `@humans` / `@all`）在內文裡也要被標起來。
///
/// 它們**不在 `mentions` 裡**——Hub 把群組展開成全房名單放進 mentions，
/// 原本打的字面留在 `mention_groups`。只用 mentions 建比對式時，
/// 內文那個 `@agents` 對不上任何名字，於是它是整則訊息裡唯一沒被標起來的
/// mention，而它偏偏涵蓋最多人。
void main() {
  test('群組 token 進得了比對式', () {
    final p = mentionPattern(['Novia', 'agents']);
    expect(RegExp(p).hasMatch('@agents 今天先這樣'), isTrue);
    expect(RegExp(p).hasMatch('@Novia 看一下'), isTrue);
  });

  test('長的優先：@all 不會被同名成員的前綴吃掉', () {
    // 房裡有人叫 al 時，'@al' 不可以先比中而讓 '@all' 只標到一半
    final p = mentionPattern(['al', 'all']);
    final m = RegExp(p).firstMatch('@all 收工');
    expect(m!.group(0), '@all');
  });

  test('unrenderedMentions 只看個別名字，不受群組影響', () {
    // 群組那條走泡泡底下的摺疊 chip（mention_groups），
    // 兩條路各自負責，混在一起會讓群組訊息底下掛出一整排全房名單
    expect(unrenderedMentions('@agents 大家好', ['Novia', 'Bernie']),
        ['Novia', 'Bernie']);
  });
}
