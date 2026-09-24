import 'dart:io';
import 'dart:typed_data';

import 'package:chatroom_app/api/rooms_api.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import '../api/identity_headers_test.dart' show Recorder;

/// 移交管理權：房主把房交給房內另一個人類成員（v1.2.4-hotfix2）。
///
/// 第一組是**行為測試**——`RoomsApi.transferAdmin` 打的是哪個端點、帶誰的
/// 身分、把誰寫進 body。這三件事 Hub 都在驗，錯一個就是 403／404。
///
/// 第二組是**形狀守衛，不是行為測試**，理由照 `member_run_badge_test.dart`
/// 與 `selection_context_menu_test.dart` 的同一段說明：`_MemberTile` 與
/// `_MembersPanel` 是 `chat_screen.dart` 的私有類別，而 ChatScreen 沒有
/// widget 測試基礎——構造不出那個窗口就不要假裝驗到了效果，寫了會得到一顆
/// 永遠綠的燈。所以這裡守的是「那四個門檻還在同一個判斷式上」。
///
/// > **什麼時候可以拿掉第二組**：成員列被抽成 `lib/widgets/` 下的公開
/// > widget、或 ChatScreen 有了 widget 測試基礎之後，改寫成「房主看得到、
/// > 非房主看不到、agent 那一列沒有」的行為測試，那時這組就該刪掉。
void main() {
  group('RoomsApi.transferAdmin', () {
    late Recorder rec;
    late RoomsApi api;

    setUp(() {
      rec = Recorder();
      api = RoomsApi(
          Dio(BaseOptions(baseUrl: 'http://test'))..httpClientAdapter = rec);
    });

    test('打房間自己的 admin 端點，body 帶接手的人', () async {
      await api.transferAdmin('r1',
          targetParticipantId: 'p-heir', participantId: 'p-me');
      final req = rec.seen.single;
      expect(req.method, 'POST');
      expect(req.path, '/api/rooms/r1/admin');
      expect(req.data, {'target_participant_id': 'p-heir'});
    });

    test('身分標頭是**呼叫者自己**的 participant id——Hub 拿它比對房主，'
        '送成目標的 id 會被退 403', () async {
      await api.transferAdmin('r1',
          targetParticipantId: 'p-heir', participantId: 'p-me');
      expect(rec.seen.single.headers['X-Participant-Id'], 'p-me');
    });

    test('回傳 Hub 認定的新管理員名字，不是本機那份快照', () async {
      final dio = Dio(BaseOptions(baseUrl: 'http://test'))
        ..httpClientAdapter = _Fixed('{"ok":true,"admin_participant_id":'
            '"p-heir","admin_display_name":"艾斯維爾"}');
      expect(
        await RoomsApi(dio).transferAdmin('r1',
            targetParticipantId: 'p-heir', participantId: 'p-me'),
        '艾斯維爾',
      );
    });

    test('舊 Hub 不回名字時是空字串，不是 null 崩掉', () async {
      expect(
        await api.transferAdmin('r1',
            targetParticipantId: 'p-heir', participantId: 'p-me'),
        '',
      );
    });
  });

  group('成員列的移交入口（形狀守衛）', () {
    late String source;

    setUp(() {
      source = File('lib/screens/chat/chat_screen.dart').readAsStringSync();
    });

    test('移交動作掛在成員列上，讀的是翻譯鍵', () {
      // 直接比中文字的話，換語言就等於把這條守衛關掉
      expect(source, contains('l10n.chatMemberTransferAdmin'),
          reason: '成員列上找不到移交管理權');
      expect(source, contains('onTransferAdmin!'),
          reason: '選單項沒有接上 onTransferAdmin，按下去不會發生事情');
    });

    test('四個門檻都在同一個判斷式上', () {
      final idx = source.indexOf('onTransferAdmin: ');
      expect(idx, isNot(-1), reason: 'onTransferAdmin 被改名了，請一起更新這條守衛');
      final window = source.substring(idx, idx + 400);
      // 非房主不可以看到它——Hub 會退 403，但畫面不該先給出一顆假的入口
      expect(window, contains('widget.youAreAdmin'), reason: '非房主也看得到移交');
      // 交給自己是一個沒有意義的動作
      expect(window, contains('p.id != myId'), reason: '自己那一列也出現移交');
      // agent 會被閒置掃掉，交給它等於把管理權丟掉（Hub 端回 422）
      expect(window, contains('p.isHuman'), reason: 'agent 那一列也出現移交');
      // 已離開的人接不了
      expect(window, contains('p.isActive'), reason: '離開的成員那一列也出現移交');
    });

    test('404 的 heir_not_found 要自己轉述——NotFoundException 只留 code', () {
      expect(source, contains("e.code == 'heir_not_found'"),
          reason: '目標已離開時會顯示一句通用的「找不到」，看的人不知道是誰不見了');
      expect(source, contains('l10n.errorHeirNotFound'));
    });

    test('移交成功要把房間詳情與房列表都重讀', () {
      final idx = source.indexOf('Future<void> _transferAdmin(');
      expect(idx, isNot(-1));
      final body = source.substring(idx, idx + 2400);
      expect(body, contains('ref.invalidate(roomDetailProvider(widget.roomId))'),
          reason: '自己已經不是房主了，但這個房的動作列還照舊給著房主的權限');
      expect(body, contains('ref.invalidate(roomListProvider)'),
          reason: '房列表上的房主標記還掛在自己身上');
    });
  });
}

/// 回一份固定 JSON 的 adapter——[Recorder] 一律回 `{"ok":true}`，
/// 驗回傳值要自己給內容。
class _Fixed implements HttpClientAdapter {
  _Fixed(this.body);

  final String body;

  @override
  Future<ResponseBody> fetch(
          RequestOptions options, Stream<Uint8List>? _, Future<void>? _) async =>
      ResponseBody.fromString(body, 200, headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      });

  @override
  void close({bool force = false}) {}
}
