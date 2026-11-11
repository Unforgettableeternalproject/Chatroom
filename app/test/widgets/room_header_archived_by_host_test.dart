import 'package:chatroom_app/core/theme/uep_theme.dart';
import 'package:chatroom_app/models/room.dart';
import 'package:chatroom_app/screens/chat/chat_screen.dart';
import 'package:chatroom_app/state/app_providers.dart';
import 'package:chatroom_app/state/messages_providers.dart';
import 'package:chatroom_app/ws/ws_protocol.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/app_config.dart';
import '../helpers/l10n.dart';

Widget _wrap({
  required bool archived,
  required bool byHost,
  String reason = '',
}) =>
    ProviderScope(
      overrides: [
        initialConfigProvider.overrideWithValue(kTestInitialConfig),
        identityProvider('r1').overrideWith(
            (ref) async => (participantId: 'p1', displayName: '測試')),
      ],
      child: MaterialApp(
        localizationsDelegates: kTestLocalizationsDelegates,
        supportedLocales: kTestSupportedLocales,
        theme: buildUepTheme(Brightness.dark),
        home: Scaffold(
          body: RoomHeader(
            roomId: 'r1',
            roomName: '測試房',
            topic: '',
            archived: archived,
            pinnedCount: 0,
            memberCount: 2,
            showMembersButton: false,
            archivedByHost: byHost,
            archiveReason: reason,
          ),
        ),
      ),
    );

void main() {
  testWidgets('主持人封存的房：標頭顯示「由主持人封存」，有理由一併帶出', (tester) async {
    await tester.pumpWidget(_wrap(archived: true, byHost: true));
    expect(find.text('由主持人封存'), findsOneWidget);

    await tester.pumpWidget(
        _wrap(archived: true, byHost: true, reason: '長期沒人用'));
    expect(find.text('由主持人封存：長期沒人用'), findsOneWidget);
  });

  testWidgets('不是主持人封存、或房沒封存：不顯示', (tester) async {
    await tester.pumpWidget(_wrap(archived: true, byHost: false));
    expect(find.byKey(const Key('archivedByHostNote')), findsNothing);

    await tester.pumpWidget(_wrap(archived: false, byHost: true));
    expect(find.byKey(const Key('archivedByHostNote')), findsNothing);
  });

  test('Room 讀得到 archived_by_host 與 archive_reason，缺值為 false／空', () {
    final r = Room.fromJson({
      'id': 'r',
      'name': 'n',
      'archived_by_host': true,
      'archive_reason': '清理',
    });
    expect(r.archivedByHost, isTrue);
    expect(r.archiveReason, '清理');
    final old = Room.fromJson({'id': 'r', 'name': 'n'});
    expect(old.archivedByHost, isFalse);
    expect(old.archiveReason, '');
  });

  test('/ws/inbox 帶 token、session_key，主持人模式帶 host_view', () {
    final u = WsProtocol.wsUri('http://hub:8787', 'tok',
        hostView: true, path: '/ws/inbox', sessionKey: 'dev-1');
    expect(u.scheme, 'ws');
    expect(u.path, '/ws/inbox');
    expect(u.queryParameters,
        {'token': 'tok', 'host_view': '1', 'session_key': 'dev-1'});
    // /ws 預設不變
    expect(WsProtocol.wsUri('https://h', 't').path, '/ws');
    expect(WsProtocol.wsUri('https://h', 't').scheme, 'wss');
  });
}
