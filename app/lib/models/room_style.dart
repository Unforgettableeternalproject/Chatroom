import 'package:flutter/foundation.dart';

import '../l10n/l10n.dart';

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

/// 說話方式的選項。文字跟著語言走，所以是 getter 而不是 `const`。
List<RoomStyleOption> get kRoomStyles {
  final l10n = L10n.current;
  return <RoomStyleOption>[
    RoomStyleOption('verbose', l10n.roomStyleVerbose, l10n.roomStyleVerboseDesc),
    RoomStyleOption('concise', l10n.roomStyleConcise, l10n.roomStyleConciseDesc),
    RoomStyleOption('casual', l10n.roomStyleCasual, l10n.roomStyleCasualDesc),
    RoomStyleOption(
        kRoomStyleCustom, l10n.roomStyleCustom, l10n.roomStyleCustomDesc),
  ];
}

/// 未知的值一律顯示成「詳細」——與 Hub 的退路一致（見 `_style_texts`）。
/// 顯示成「未知」只會讓人以為房間壞了，而 agent 那邊其實運作正常。
String roomStyleLabel(String value) {
  for (final o in kRoomStyles) {
    if (o.value == value) return o.label;
  }
  return kRoomStyles.first.label;
}
