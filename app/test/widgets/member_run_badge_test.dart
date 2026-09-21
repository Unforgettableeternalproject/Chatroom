import 'dart:io';

import 'package:chatroom_app/models/participant.dart';
import 'package:flutter_test/flutter_test.dart';

/// 派工帶進房的成員在成員列上是「派工中」，**不是一個正在倒數的閒置者**。
///
/// 病灶：Hub 那一端已經豁免這些成員（run 還在跑就不掃，且 hold 一路續），
/// 但 App 自己拿 `last_seen` 算「閒置 N 分 · 最快 M 分後移出」——於是畫面
/// 對一個永遠不會被移出的成員倒數，使用者以為 hold 沒生效。
///
/// ---
///
/// 第二組是**形狀守衛，不是行為測試**：`_MemberTile` 與 `_MembersPanel` 都是
/// `chat_screen.dart` 的私有類別，而 ChatScreen 沒有 widget 測試基礎（見
/// `selection_context_menu_test.dart` 的同一段說明）——構造不出那個窗口就不要
/// 假裝驗到了效果。
///
/// > **什麼時候可以拿掉這組**：成員列被抽成 `lib/widgets/` 下的公開 widget、
/// > 或 ChatScreen 有了 widget 測試基礎之後，改寫成「runId 非空時畫面出現
/// > 派工中、且沒有倒數文字」的行為測試，那時這組就該刪掉。
void main() {
  group('Participant.runId', () {
    Participant parse(Map<String, dynamic> json) => Participant.fromJson({
          'id': 'p1',
          'display_name': '執行代理',
          'role': 'agent',
          'status': 'active',
          'joined_at': '2026-09-18T00:00:00+00:00',
          ...json,
        });

    test('Hub 帶 run_id 時是派工中', () {
      expect(parse({'run_id': 'run-1'}).isOnRun, isTrue);
    });

    test('空字串＝一般成員', () {
      expect(parse({'run_id': ''}).isOnRun, isFalse);
    });

    test('舊 Hub 不回這個欄位時當一般成員，不是 null 崩掉', () {
      final p = parse({});
      expect(p.runId, '');
      expect(p.isOnRun, isFalse);
    });

    test('runId 改變算不同的人（列要重畫）', () {
      // 少了這一項，成員從一般變成派工中時那一列不會更新——`==` 說它沒變
      expect(parse({'run_id': 'run-1'}) == parse({'run_id': ''}), isFalse);
    });
  });

  group('成員列的派工中標記（形狀守衛）', () {
    late String source;

    setUp(() {
      source = File('lib/screens/chat/chat_screen.dart').readAsStringSync();
    });

    test('派工中的成員掛金色標籤', () {
      // 文案抽成翻譯鍵之後，守的是**那顆徽章讀的是哪一個鍵**——
      // 直接比中文字的話，換語言就等於把這條守衛關掉
      expect(source, contains('label: l10n.chatBadgeOnRun'),
          reason: '成員列上看不出它正在替一筆派工工作');
    });

    test('派工中的成員不算閒置——倒數那一支不可以碰得到它', () {
      final idx = source.indexOf('final isIdle =');
      expect(idx, isNot(-1), reason: '閒置判定被改名了，請一起更新這條守衛');
      final window = source.substring(idx, idx + 120);
      expect(window, contains('!onRun'),
          reason: '閒置判定沒有排除派工中的成員 ⇒ 那一列會印「最快 N 分後移出」，'
              '而 Hub 根本不會移出它。'
              '修法：`onRun` 進 isIdle 的條件，不要改倒數那段文案');
    });

    test('倒數文案只掛在閒置分支上', () {
      // 反向守衛：倒數本身是對的，錯的是「誰會走到它」。
      // 有人把 `後移出` 搬到別的分支時這條會紅
      final branch = source.indexOf('} else if (isIdle) {');
      expect(branch, isNot(-1));
      // 文案抽成翻譯鍵之後找那個鍵的呼叫；鍵名不會出現在註解裡，
      // 所以仍然只數到真正會被畫出來的那一處
      final copy = source.indexOf('l10n.chatMemberIdleWithRemain(');
      expect(copy, isNot(-1), reason: '倒數文案被改名了，請一起更新這條守衛');
      expect(copy, greaterThan(branch),
          reason: '倒數文案跑到閒置分支之前了——派工中的成員會讀到它');
      expect(source.indexOf('l10n.chatMemberIdleWithRemain(', copy + 1), -1,
          reason: '倒數文案出現在第二個地方，這條守衛只守得住第一個');
    });
  });
}
