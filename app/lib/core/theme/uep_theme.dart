import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'uep_tokens.dart';

/// 字型層：對照設計稿的 --font-display（Cormorant Garamond）、
/// --font-serif-tc（Noto Serif TC）、--font-sans（Inter）、--font-mono（JetBrains Mono）。
/// google_fonts 執行期抓字型並快取；離線時退回系統字型，版面不炸。
class UepText {
  UepText._();

  static TextStyle display({
    double size = 26,
    FontWeight weight = FontWeight.w600,
    Color? color,
    double? height,
  }) =>
      GoogleFonts.cormorantGaramond(
        fontSize: size, fontWeight: weight, color: color, height: height);

  static TextStyle serif({
    double size = 14.5,
    FontWeight weight = FontWeight.w400,
    Color? color,
    double height = 1.85,
  }) =>
      GoogleFonts.notoSerifTc(
        fontSize: size, fontWeight: weight, color: color, height: height);

  static TextStyle sans({
    double size = 13.5,
    FontWeight weight = FontWeight.w400,
    Color? color,
    double? height,
  }) =>
      GoogleFonts.inter(
        fontSize: size, fontWeight: weight, color: color, height: height);

  /// mono 小字 uppercase 標籤——設計稿最鮮明的識別元素。
  static TextStyle mono({
    double size = 9,
    FontWeight weight = FontWeight.w400,
    Color? color,
    double letterSpacing = 1.4,
    double? height,
  }) =>
      GoogleFonts.jetBrainsMono(
        fontSize: size,
        fontWeight: weight,
        color: color,
        letterSpacing: letterSpacing,
        height: height,
      );

  /// 程式碼區塊 / 行內 code 用（不加 letterSpacing）。
  static TextStyle code({
    double size = 12.5,
    Color? color,
    double height = 1.7,
  }) =>
      GoogleFonts.jetBrainsMono(
        fontSize: size, color: color, height: height);
}

ThemeData buildUepTheme(Brightness brightness) {
  final s = brightness == Brightness.dark ? UepSurface.dark : UepSurface.light;
  final base = ThemeData(
    brightness: brightness,
    useMaterial3: true,
    scaffoldBackgroundColor: s.bg,
    colorScheme: ColorScheme(
      brightness: brightness,
      primary: UepColors.gold,
      onPrimary: UepColors.goldInkOn,
      secondary: s.inkSoft,
      onSecondary: s.bg,
      error: UepColors.error,
      onError: Colors.black,
      surface: s.bgCard,
      onSurface: s.ink,
    ),
    splashFactory: InkSparkle.splashFactory,
  );
  return base.copyWith(
    extensions: [s],
    dividerColor: s.line,
    textTheme: base.textTheme.apply(
      bodyColor: s.ink,
      displayColor: s.inkTitle,
      fontFamily: GoogleFonts.inter().fontFamily,
    ),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: UepColors.gold,
      selectionColor: UepColors.gold.withValues(alpha: .25),
      selectionHandleColor: UepColors.gold,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: s.bgCard,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: s.lineStrong),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: s.bgCard,
      contentTextStyle: UepText.serif(size: 13, color: s.ink, height: 1.5),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: s.lineStrong),
      ),
      behavior: SnackBarBehavior.floating,
    ),
    scrollbarTheme: ScrollbarThemeData(
      thumbColor: WidgetStatePropertyAll(s.inkMute.withValues(alpha: .35)),
      radius: const Radius.circular(4),
      thickness: const WidgetStatePropertyAll(6),
    ),
  );
}
