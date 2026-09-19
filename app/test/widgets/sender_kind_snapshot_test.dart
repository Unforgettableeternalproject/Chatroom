import 'package:chatroom_app/core/theme/uep_theme.dart';
import 'package:chatroom_app/core/theme/uep_tokens.dart';
import 'package:chatroom_app/models/message.dart';
import 'package:chatroom_app/widgets/kind_badge.dart';
import 'package:chatroom_app/widgets/message_bubble.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import '../helpers/l10n.dart';

/// 訊息自帶的 sender kind 快照。
///
/// run 成員結束後不留在成員名冊裡，只靠名冊反查的畫面會把它們的歷史發言
/// 退成 OTHER——徽章說謊，而畫面上看不出是資料少了還是那個人真的沒有 kind。
/// 這份測試釘的是「快照優先於名冊」，以及兩邊都沒有時才回 other。
Message _msg(Map<String, dynamic> extra) => Message.fromJson({
      'id': 'm1',
      'seq': 1,
      'update_seq': 0,
      'kind': 'chat',
      'content': '跑完了',
      'created_at': '2026-09-01T00:00:00+00:00',
      'sender_id': 'run-1',
      'sender_name': 'Novia(run)',
      ...extra,
    });

Widget _wrap(Widget child) => MaterialApp(
  localizationsDelegates: kTestLocalizationsDelegates,
  supportedLocales: kTestSupportedLocales,
      theme: buildUepTheme(Brightness.dark),
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

void main() {
  test('sender_kind 缺鍵或空字串 → null', () {
    expect(_msg(const {}).senderKind, isNull);
    expect(_msg(const {'sender_kind': ''}).senderKind, isNull);
    expect(_msg(const {'sender_kind': 'claude'}).senderKind, 'claude');
  });

  test('名冊查不到，訊息自帶 sender_kind → 用快照', () {
    final m = _msg(const {'sender_kind': 'claude'});
    expect(m.resolveSenderKind(const {}), 'claude');
  });

  test('沒有快照 → 反查名冊；名冊也沒有 → other', () {
    final m = _msg(const {});
    expect(m.resolveSenderKind(const {'run-1': 'codex'}), 'codex');
    expect(m.resolveSenderKind(const {}), 'other');
  });

  test('快照壓過名冊：離房重進的 id 被別人拿去也不改寫歷史', () {
    final m = _msg(const {'sender_kind': 'claude'});
    expect(m.resolveSenderKind(const {'run-1': 'human'}), 'claude');
  });

  testWidgets('名冊查不到但訊息帶 sender_kind: claude → 徽章是 CLAUDE',
      (tester) async {
    final m = _msg(const {'sender_kind': 'claude'});
    await tester.pumpWidget(_wrap(MessageBubble(
      message: m,
      isSelf: false,
      senderKind: m.resolveSenderKind(const {}),
    )));
    expect(find.text('OTHER'), findsNothing);
    expect(find.text('CLAUDE'), findsWidgets);
    final badge = tester.widget<KindBadge>(find.byType(KindBadge).first);
    expect(badge.kind, 'claude');
    expect(kindColor(badge.kind, context: tester.element(find.byType(KindBadge).first)),
        UepColors.kindClaude);
  });
}
