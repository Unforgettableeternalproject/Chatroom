import 'package:flutter/foundation.dart';

/// 房內 agent 的說話方式，UI 端的顯示定義。
///
/// ⚠️ 這裡的 [description] 是**給人看的一句話**，不是送給 agent 的指示。
/// 真正的指示寫在 Hub（`server/chatroom_server/app.py` 的 `ROOM_STYLES`），
/// 由 join / read 的回應帶給 agent。改這裡不會改變任何 agent 的行為——
/// 要改行為請改 Hub 那份。分開放是因為所有進房的 agent 必須拿到同一份
/// 定義，而 App 只是眾多 client 之一。
@immutable
class RoomStyleOption {
  const RoomStyleOption(this.value, this.label, this.description);

  final String value;
  final String label;
  final String description;
}

const kRoomStyleCustom = 'custom';

const kRoomStyles = <RoomStyleOption>[
  RoomStyleOption('verbose', '詳細', '完整交付：任務結果、程式碼、Markdown 報告，篇幅不限'),
  RoomStyleOption('concise', '精確', '只列重點，不貼程式碼與長篇文件'),
  RoomStyleOption('casual', '親和', '像人一樣說話，不報告工作階段'),
  RoomStyleOption(kRoomStyleCustom, '自訂', '自己寫下這個房間的說話方式'),
];

/// 未知的值一律顯示成「詳細」——與 Hub 的退路一致（見 `_style_texts`）。
/// 顯示成「未知」只會讓人以為房間壞了，而 agent 那邊其實運作正常。
String roomStyleLabel(String value) {
  for (final o in kRoomStyles) {
    if (o.value == value) return o.label;
  }
  return kRoomStyles.first.label;
}
