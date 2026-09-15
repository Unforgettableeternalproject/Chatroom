import 'package:chatroom_app/core/config/invite_code.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('邀請碼', () {
    test('編碼後解得回同一份邀請', () {
      const invite = InviteCode(
        serverUrl: 'http://192.168.1.10:8787',
        token: 'abc123',
        label: '戴爾',
      );
      final parsed = InviteCode.tryParse(invite.encode())!;
      expect(parsed.serverUrl, invite.serverUrl);
      expect(parsed.token, invite.token);
      expect(parsed.label, invite.label);
    });

    test('不是網址——貼進聊天軟體不該被自動連結或被預覽服務展開', () {
      const invite =
          InviteCode(serverUrl: 'https://x.trycloudflare.com', token: 't');
      final code = invite.encode();
      expect(code.startsWith('http'), isFalse);
      expect(code.contains('://'), isFalse);
      // token 也不該以明碼出現在這串字裡
      expect(code.contains('t='), isFalse);
    });

    test('前後空白與換行不影響解析（聊天軟體常會加上去）', () {
      const invite =
          InviteCode(serverUrl: 'http://h:8787', token: 'tok');
      expect(InviteCode.tryParse('\n  ${invite.encode()}  \n')?.token, 'tok');
    });

    test('沒有版本前綴的字串不是邀請碼', () {
      expect(InviteCode.tryParse('隨便貼的一段字'), isNull);
      expect(InviteCode.tryParse(''), isNull);
    });

    test('前綴對但內容壞掉時回 null，不可拋例外', () {
      expect(InviteCode.tryParse('CHATROOM-INVITE-1.@@@不是base64'), isNull);
    });

    test('缺 url 或 token 的邀請不成立——填一半的設定比沒設定更難查', () {
      expect(
          InviteCode.tryParse(
              const InviteCode(serverUrl: '', token: 't').encode()),
          isNull);
      expect(
          InviteCode.tryParse(
              const InviteCode(serverUrl: 'http://h', token: '').encode()),
          isNull);
    });

    test('label 是選填，缺了照樣能用', () {
      const invite = InviteCode(serverUrl: 'http://h', token: 't');
      expect(InviteCode.tryParse(invite.encode())?.label, '');
    });
  });

  group('isLoopbackUrl', () {
    test('只有主持人自己連得到的位址一律認出來', () {
      for (final url in [
        'http://127.0.0.1:8787',
        'http://localhost:8787',
        'http://LOCALHOST',
        'http://0.0.0.0:8787',
        'http://[::1]:8787',
        'http://127.0.1.1:8787',
      ]) {
        expect(isLoopbackUrl(url), isTrue, reason: url);
      }
    });

    test('外面連得到的位址不要誤擋', () {
      for (final url in [
        'https://mae-sensitive-roads-cleared.trycloudflare.com',
        'http://192.168.1.20:8787',
        'http://26.176.231.43:8787',
        'http://hub.example.com',
      ]) {
        expect(isLoopbackUrl(url), isFalse, reason: url);
      }
    });

    test('解析不出來的東西不算本機——擋錯比漏擋更煩人', () {
      expect(isLoopbackUrl('這不是網址'), isFalse);
      expect(isLoopbackUrl(''), isFalse);
    });
  });

}
