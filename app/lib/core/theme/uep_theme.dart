import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../config/app_settings.dart';
import 'uep_tokens.dart';

/// 字型層：對照設計稿的 --font-display（Cormorant Garamond）、
/// --font-serif-tc（Noto Serif TC）、--font-sans（Inter）、--font-mono（JetBrains Mono）。
/// google_fonts 執行期抓字型並快取；離線時退回系統字型，版面不炸。
class UepText {
  UepText._();

  /// 全域字體選擇；由 `app.dart` 依 AppConfig 寫入。
  ///
  /// 放靜態而不是吃 context：UepText 是一組無 context 的純函式，整個 App 的
  /// 每個呼叫點都改成要 context 的代價太大。代價是換字體不會自動觸發重建，
  /// 由 `app.dart` 用 key 重建整棵樹補上。
  static FontFamilyPref family = FontFamilyPref.standard;

  /// 打包在 assets 的家族名，對應 pubspec 的 `fonts:` 宣告。
  /// `standard` 沒有對應檔案，回 null＝走 google_fonts 原本那套。
  static String? familyName(FontFamilyPref pref) => switch (pref) {
        FontFamilyPref.standard => null,
        FontFamilyPref.iansui => 'Iansui',
        FontFamilyPref.openhuninn => 'jf-openhuninn',
        FontFamilyPref.chenyuluoyan => 'ChenYuluoyan',
        FontFamilyPref.glowsans => 'GlowSansTC',
      };

  /// 自訂字體缺字時的退路。這幾套的字數各不相同，沒有 fallback 的話
  /// 罕用字會變成方塊。
  ///
  /// serif／display 退到 Noto Serif TC；sans 先退 Inter（拉丁字母才不會
  /// 跟著變成中文字體的西文）再退 Noto Serif TC。
  static List<String> get _serifFallback =>
      [?GoogleFonts.notoSerifTc().fontFamily];

  static List<String> get sansFallback => _sansFallback;

  static List<String> get _sansFallback => [
        ?GoogleFonts.inter().fontFamily,
        ?GoogleFonts.notoSerifTc().fontFamily,
      ];

  static TextStyle display({
    double size = 26,
    FontWeight weight = FontWeight.w600,
    Color? color,
    double? height,
  }) {
    final custom = familyName(family);
    if (custom == null) {
      return GoogleFonts.cormorantGaramond(
          fontSize: size, fontWeight: weight, color: color, height: height);
    }
    return TextStyle(
      fontFamily: custom,
      fontFamilyFallback: _serifFallback,
      fontSize: size,
      fontWeight: weight,
      color: color,
      height: height,
    );
  }

  /// 頁面主標：AppBar 標題、頁內大標、對話框標題。
  static TextStyle pageTitle({Color? color, double? height}) =>
      display(size: 26, color: color, height: height);

  /// 區塊標題：一段內容的開頭。
  static TextStyle sectionTitle({Color? color, double? height}) =>
      display(size: 20, color: color, height: height);

  /// 列表項／卡片標題。
  static TextStyle itemTitle({Color? color, double? height}) =>
      display(size: 17, color: color, height: height);

  /// 區塊小標／徽章：mono 全大寫或中文短標，靠字距拉出標籤感。
  static TextStyle label(
          {Color? color, double size = 10.5, double letterSpacing = 1.6}) =>
      mono(size: size, color: color, letterSpacing: letterSpacing);

  /// 欄位標籤：緊貼輸入框、開關或狀態值，說明「這一欄是什麼」。
  ///
  /// 比 [label] 大一級：那些字要跟旁邊的值一起讀，縮到徽章的尺寸會讀不動。
  static TextStyle fieldLabel({Color? color, double letterSpacing = 1.2}) =>
      mono(size: 12, weight: FontWeight.w500, color: color,
          letterSpacing: letterSpacing);

  static TextStyle serif({
    double size = 15,
    FontWeight weight = FontWeight.w400,
    Color? color,
    double height = 1.85,
  }) {
    final custom = familyName(family);
    if (custom == null) {
      return GoogleFonts.notoSerifTc(
          fontSize: size, fontWeight: weight, color: color, height: height);
    }
    return TextStyle(
      fontFamily: custom,
      fontFamilyFallback: _serifFallback,
      fontSize: size,
      fontWeight: weight,
      color: color,
      height: height,
    );
  }

  static TextStyle sans({
    double size = 14.5,
    FontWeight weight = FontWeight.w400,
    Color? color,
    double? height,
  }) {
    final custom = familyName(family);
    if (custom == null) {
      return GoogleFonts.inter(
          fontSize: size, fontWeight: weight, color: color, height: height);
    }
    return TextStyle(
      fontFamily: custom,
      fontFamilyFallback: _sansFallback,
      fontSize: size,
      fontWeight: weight,
      color: color,
      height: height,
    );
  }

  /// mono 小字 uppercase 標籤——設計稿最鮮明的識別元素。
  static TextStyle mono({
    double size = 10,
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
    double size = 13,
    Color? color,
    double height = 1.7,
  }) =>
      GoogleFonts.jetBrainsMono(
        fontSize: size, color: color, height: height);
}

/// 字級五檔對應的整體縮放倍率——套在 MediaQuery 的 textScaler 上，
/// 所有硬編碼字級一起放大，版面比例不變。
double fontScaleFactor(FontScalePref pref) {
  switch (pref) {
    case FontScalePref.tiny:
      return 0.5;
    case FontScalePref.small:
      return 0.9;
    case FontScalePref.medium:
      return 1.0;
    case FontScalePref.large:
      return 1.15;
    case FontScalePref.xlarge:
      return 1.3;
  }
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
    // 沒經過 UepText 的 Text（第三方 widget、Material 內建元件）從這裡拿字族。
    // 讀 UepText.family 而不是加參數：判準只有一個，呼叫端不必各自傳
    textTheme: base.textTheme.apply(
      bodyColor: s.ink,
      displayColor: s.inkTitle,
      fontFamily: UepText.sans().fontFamily,
      fontFamilyFallback: UepText.sans().fontFamilyFallback,
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
      contentTextStyle: UepText.serif(size: 14, color: s.ink, height: 1.5),
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
