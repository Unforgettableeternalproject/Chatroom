import 'package:chatroom_app/models/agent_session.dart';
import 'package:flutter_test/flutter_test.dart';

/// 指派候選的裝置歸屬。
///
/// 為什麼要分：指派是私人房的入場券（Hub 的 `_invited_to_private` 認的就是
/// assignment），把別人機器上的 agent 指派進來等於把房裡的內容送出去。
void main() {
  AgentSession session({String? host}) => AgentSession.fromJson({
        'session_key': 'claude-abc',
        'kind': 'claude',
        'label': 'Novia',
        'status': 'active',
        'last_seen_at': '2026-08-30T00:00:00Z',
        'rooms': const [],
        'host': ?host,
      });

  test('同一台機器算本機', () {
    expect(session(host: 'BERNIE-PC').isOnHost('BERNIE-PC'), isTrue);
  });

  test('大小寫不同仍是同一台', () {
    // Windows 慣用大寫、Dart 拿到的可能是小寫，同一台不該被判成兩台
    expect(session(host: 'BERNIE-PC').isOnHost('bernie-pc'), isTrue);
  });

  test('別台機器不算本機', () {
    expect(session(host: 'OTHER-PC').isOnHost('BERNIE-PC'), isFalse);
  });

  test('舊版 bridge 沒報主機名時，不能算成本機', () {
    // 空值＝未知裝置。當成本機的話，每一台報不出主機名的機器都會混進
    // 本機清單，而這正是這個功能要擋的事
    expect(session().host, '');
    expect(session().isOnHost('BERNIE-PC'), isFalse);
    expect(session(host: '').isOnHost('BERNIE-PC'), isFalse);
  });

  test('讀不到自己的主機名時，誰都不算本機', () {
    // 這種情況 UI 會改成照列全部並說明原因，而不是宣稱「全都是本機」
    expect(session(host: 'BERNIE-PC').isOnHost(''), isFalse);
  });
}
