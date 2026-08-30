import 'package:chatroom_app/models/room.dart';
import 'package:chatroom_app/models/room_style.dart';
import 'package:flutter_test/flutter_test.dart';

/// 說話方式：Hub 決定 agent 怎麼講話，App 只負責顯示與切換。
///
/// 預設值同樣是最重要的一件事：舊版 Hub 不回 `style`，那時一律當成
/// verbose——那正是這個設定存在之前的實際行為。
void main() {
  Map<String, dynamic> json(Map<String, dynamic> extra) => {
        'id': 'r1',
        'name': '房',
        'topic': '',
        'status': 'active',
        'created_at': '2026-08-30T00:00:00Z',
        ...extra,
      };

  test('沒有 style 欄位時視為詳細（舊版 Hub）', () {
    final room = Room.fromJson(json({}));
    expect(room.style, 'verbose');
    expect(room.styleInstructions, '');
    expect(room.isCustomStyle, isFalse);
  });

  test('自訂風格連指示原文一起帶回來', () {
    final room = Room.fromJson(json({
      'style': 'custom',
      'style_instructions': '一律用英文回答。',
    }));
    expect(room.isCustomStyle, isTrue);
    expect(room.styleInstructions, '一律用英文回答。');
  });

  test('copyWith 不指定時保留說話方式', () {
    final room = Room.fromJson(json({'style': 'concise'}));
    expect(room.copyWith(status: 'archived').style, 'concise');
    expect(room.copyWith(style: 'casual').style, 'casual');
    // 鎖定狀態與說話方式互不干擾
    expect(room.copyWith(visibility: 'private').style, 'concise');
  });

  test('四個選項都有標籤，custom 排最後', () {
    expect(kRoomStyles.map((o) => o.value).toList(),
        ['verbose', 'concise', 'casual', 'custom']);
    expect(roomStyleLabel('concise'), '精確');
    expect(roomStyleLabel('casual'), '親和');
    expect(roomStyleLabel('custom'), '自訂');
  });

  test('沒見過的風格顯示成詳細，與 Hub 的退路一致', () {
    // 顯示成「未知」只會讓人以為房間壞了，而 agent 那邊其實運作正常
    expect(roomStyleLabel('telepathy'), '詳細');
  });
}
