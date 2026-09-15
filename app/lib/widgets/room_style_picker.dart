import 'package:flutter/material.dart';

import '../core/theme/uep_theme.dart';
import '../core/theme/uep_tokens.dart';
import '../models/room_style.dart';

/// 四個說話方式的單選清單（建立房間與變更說話方式共用）。
///
/// 做成清單而不是下拉選單：這四個選項的差別在**說明**，不在名字。
/// 「精確」與「親和」單看兩個字看不出差在哪，收進下拉選單裡就變成
/// 靠猜的了。
class RoomStylePicker extends StatelessWidget {
  const RoomStylePicker({
    super.key,
    required this.value,
    required this.onChanged,
    this.enabled = true,
  });

  final String value;
  final ValueChanged<String> onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    return Column(
      children: [
        for (final o in kRoomStyles)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: InkWell(
              onTap: enabled ? () => onChanged(o.value) : null,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
                decoration: BoxDecoration(
                  color: o.value == value ? s.bgSunken : Colors.transparent,
                  border: Border.all(
                      color: o.value == value ? s.lineStrong : s.line),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 1),
                      child: Icon(
                        o.value == value
                            ? Icons.radio_button_checked
                            : Icons.radio_button_unchecked,
                        size: 15,
                        color: o.value == value ? s.ink : s.inkMute,
                      ),
                    ),
                    const SizedBox(width: 9),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(o.label,
                              style: UepText.sans(size: 12.5, color: s.ink)),
                          const SizedBox(height: 2),
                          Text(o.description,
                              style: UepText.serif(
                                  size: 11.5, color: s.inkMute, height: 1.4)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}
