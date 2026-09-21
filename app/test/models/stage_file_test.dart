import 'package:chatroom_app/models/board.dart';
import 'package:chatroom_app/models/stage_file.dart';
import 'package:flutter_test/flutter_test.dart';

/// 階段素材的解析（契約 2026-09-17）。
///
/// 兩件事分開測：欄位對不對，以及**舊 Hub 沒有 `files` 這個鍵時會怎樣**。
/// 後者不是邊界情況——Hub 端的實作還沒上線，而 App 這半邊已經在跑了。
void main() {
  group('StageFile.fromJson', () {
    test('照契約的欄位名解析', () {
      final f = StageFile.fromJson(const {
        'id': 'sf1',
        'checklist_id': 'c1',
        'attachment_id': 'a1',
        'filename': 'shot.png',
        'mime': 'image/png',
        'size': 2048,
        'added_by': 'claude:novia',
        'added_by_name': '諾薇亞',
        'note': '修好之後的畫面',
        'created_at': '2026-09-17T10:00:00Z',
      });

      expect(f.id, 'sf1');
      expect(f.checklistId, 'c1');
      expect(f.attachmentId, 'a1');
      expect(f.filename, 'shot.png');
      expect(f.size, 2048);
      expect(f.addedByName, '諾薇亞');
      expect(f.note, '修好之後的畫面');
      expect(f.isImage, isTrue);
      expect(f.readableSize, '2 KB');
    });

    test('轉成附件時 id 用 attachment_id——下載打的是那條路徑', () {
      final f = StageFile.fromJson(const {
        'id': 'sf1',
        'attachment_id': 'a1',
        'filename': 'run.log',
        'mime': 'text/plain',
        'size': 10,
      });

      expect(f.asAttachment.id, 'a1');
      expect(f.asAttachment.filename, 'run.log');
      expect(f.asAttachment.isImage, isFalse);
    });
  });

  group('checklist 的 files', () {
    test('帶 files 時解析出素材', () {
      final c = BoardChecklist.fromJson(const {
        'id': 'c1',
        'room_id': 'r1',
        'objective_id': 'o1',
        'title': 'Hub 端',
        'files': [
          {'id': 'sf1', 'attachment_id': 'a1', 'filename': 'spec.md'},
        ],
      });

      expect(c.files, hasLength(1));
      expect(c.files.single.filename, 'spec.md');
    });

    test('🔴 缺 files 鍵時是空列表，不是例外——舊 Hub 不能讓整塊板讀不出來',
        () {
      final c = BoardChecklist.fromJson(const {
        'id': 'c1',
        'room_id': 'r1',
        'objective_id': 'o1',
        'title': 'Hub 端',
      });

      expect(c.files, isEmpty);
    });

    test('files 不是清單（null 或別的型別）時同樣退成空列表', () {
      expect(StageFile.listFrom(null), isEmpty);
      expect(StageFile.listFrom('x'), isEmpty);
    });
  });
}
