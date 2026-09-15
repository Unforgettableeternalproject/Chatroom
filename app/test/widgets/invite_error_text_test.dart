import 'package:chatroom_app/core/errors/api_exception.dart';
import 'package:chatroom_app/widgets/invite_manager.dart';
import 'package:flutter_test/flutter_test.dart';

/// d49687c5：發邀請拿到 403 時不能留一個看不懂的錯誤。
///
/// 🔴 `root_token_required` 有**兩種來源**，Hub 兩種都回同一個 code：
/// 這台是別人主持的（舊的那種），以及**手上這張憑證的 audience 是 human**
/// （2026-09-07 憑證分離之後才有的）。App 分不出是哪一種——它看不到自己
/// 那把 token 的 audience。
///
/// 所以文案必須**兩種都成立**：講「這張憑證」，不講「你不是主持人」。
/// 後者在第二種情況下是錯的，而那正是艾斯維爾換完憑證後會遇到的那一種：
/// 他就是主持人，畫面卻說他不是。
void main() {
  test('🔴 root_token_required：講憑證，不講「你不是主持人」', () {
    final text = inviteErrorText(const RootTokenRequiredException());
    expect(text, contains('這張憑證發不了邀請'));
    expect(text, contains('主憑證'));
    // 是已知限制不是故障——不講的話，看的人會先去查自己弄壞了什麼
    expect(text, contains('不是故障'));
    expect(text, isNot(contains('只有 Hub 主持人')));
  });

  test('Hub 給了原話時仍走這句——這個 code 的兩種來源都要涵蓋', () {
    // Hub 對 root 的 403 會附自己的訊息，而那句話講的是舊的那種來源。
    // 這裡刻意蓋掉它：App 分不出來源，只能說一句兩種都成立的話
    final text =
        inviteErrorText(const RootTokenRequiredException('只有主持人可以發放邀請'));
    expect(text, contains('這張憑證發不了邀請'));
  });

  test('其他 API 錯誤照 Hub 原話——不要被這次的特化蓋掉', () {
    expect(inviteErrorText(const AuthException()), 'API token 無效，請至設定檢查');
  });

  test('非 ApiException 走讀取失敗的說法', () {
    expect(inviteErrorText(Exception('boom')), '無法讀取已發出的邀請');
  });
}
