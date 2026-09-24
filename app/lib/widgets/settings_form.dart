/// 設定頁共用的表單零件：欄位小標、輸入框外殼、輸入框裝飾。
///
/// 原本是設定頁（`settings_screen.dart`）的私有 helper；房間設定與任務板
/// 設定各自抄了一份更小的字級，畫面上就讀得出是兩個人做的，而且字小到在
/// 「大」字級下仍然看不清（艾斯維爾 2026-09-24）。搬到這裡讓三頁共用同一份。
library;

import 'package:flutter/material.dart';

import '../core/theme/uep_theme.dart';
import '../core/theme/uep_tokens.dart';

/// 欄位小標。
///
/// 不用 [MonoLabel]：它會把文字轉大寫，而這裡的標籤已經是中文與
/// 大小寫有意義的專有名詞（`API token`），轉過去就回不來了。
class SettingsFieldLabel extends StatelessWidget {
  const SettingsFieldLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 7),
      child: Text(
        text,
        style: UepText.fieldLabel(color: context.uep.inkSoft),
      ),
    );
  }
}

/// 輸入框的外殼：深色底、粗一級的框線、圓角 8。
class SettingsInputBox extends StatelessWidget {
  const SettingsInputBox({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    return Container(
      decoration: BoxDecoration(
        color: s.bgSunken,
        border: Border.all(color: s.lineStrong),
        borderRadius: BorderRadius.circular(8),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 2),
      child: child,
    );
  }
}

/// 放進 [SettingsInputBox] 的 TextField 用的裝飾：無框、緊湊。
InputDecoration settingsInputDecoration(String? hint, UepSurface s) =>
    InputDecoration(
      isDense: true,
      border: InputBorder.none,
      hintText: hint,
      hintStyle: UepText.serif(size: 12.5, color: s.inkMute),
      contentPadding: const EdgeInsets.symmetric(vertical: 10),
    );
