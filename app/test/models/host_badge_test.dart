import 'package:chatroom_app/models/participant.dart';
import 'package:flutter_test/flutter_test.dart';

/// HOST 標籤的顯示判準。
///
/// Hub 端在 join 當下記 `joined_as_host`，判準原本只有「這次用的是不是主
/// token」——而 bridge 用的就是 `.env` 那把主 token，所以**每一個** agent
/// 都被記成主持人。Hub 已補上 role 條件，但既有資料庫裡那些列改不回來，
/// 所以顯示層也要擋。
Participant _p({required String role, required bool isHost}) => Participant(
      id: 'p1',
      kind: role == 'human' ? 'human' : 'claude',
      displayName: 'X',
      role: role,
      status: 'active',
      joinedAt: '',
      isHost: isHost,
    );

void main() {
  test('拿主 token 進來的人是主持人', () {
    expect(_p(role: 'human', isHost: true).showsHostBadge, isTrue);
  });

  test('agent 即使被記成 host 也不掛標籤——舊資料就長這樣', () {
    expect(_p(role: 'agent', isHost: true).showsHostBadge, isFalse);
  });

  test('沒被記成 host 的人當然也不掛', () {
    expect(_p(role: 'human', isHost: false).showsHostBadge, isFalse);
  });
}
