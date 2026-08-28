import 'package:flutter/material.dart';

/// U.E.P Imaginary Space 設計系統 token。
/// 值逐字對照 design system 的 tokens/colors.css 與 tokens/zones.css，
/// 不要在這裡「順手調色」——設計稿才是真相來源。
class UepColors {
  UepColors._();

  // Brand
  static const gold = Color(0xFFD5B618);
  static const goldSoft = Color(0xFFE9CD3F);
  static const goldInkOn = Color(0xFF221D05); // 金底上的深色字（設計稿 #221d05）

  // Status
  static const success = Color(0xFF34D399);
  static const error = Color(0xFFF87171);
  static const info = Color(0xFF60A5FA);
  static const errorText = Color(0xFFB86060);

  // Agent kind 色軸（設計稿的訊息左側色條）
  static const kindClaude = Color(0xFF3DCC82);
  static const kindCodex = Color(0xFF5A98CC);
  static const kindHuman = gold;
  static const kindOther = Color(0xFFD98A3A);
}

/// 依主題切換的表面／墨色組。以 ThemeExtension 掛進 ThemeData，
/// widget 端用 `context.uep` 取用。
@immutable
class UepSurface extends ThemeExtension<UepSurface> {
  const UepSurface({
    required this.bg,
    required this.bgSoft,
    required this.bgCard,
    required this.bgSunken,
    required this.line,
    required this.lineStrong,
    required this.ink,
    required this.inkSoft,
    required this.inkMute,
    required this.inkTitle,
    required this.hairline,
    required this.hairlineStrong,
  });

  final Color bg;
  final Color bgSoft;
  final Color bgCard;
  final Color bgSunken;
  final Color line;
  final Color lineStrong;
  final Color ink;
  final Color inkSoft;
  final Color inkMute;
  final Color inkTitle;
  final Color hairline;
  final Color hairlineStrong;

  static const dark = UepSurface(
    bg: Color(0xFF14151A),
    bgSoft: Color(0xFF1B1D24),
    bgCard: Color(0xFF20232C),
    bgSunken: Color(0xFF0E0F13),
    line: Color(0x14FFFFFF), // rgba(255,255,255,.08)
    lineStrong: Color(0x2EFFFFFF), // .18
    ink: Color(0xFFECE9DF),
    inkSoft: Color(0xFFB3AE9F),
    inkMute: Color(0xFF7A7669),
    inkTitle: Color(0xFFFFFFFF),
    hairline: Color(0x1AFFFFFF), // .1
    hairlineStrong: Color(0x38FFFFFF), // .22
  );

  static const light = UepSurface(
    bg: Color(0xFFFAFAF7),
    bgSoft: Color(0xFFF4F2EB),
    bgCard: Color(0xFFFFFFFF),
    bgSunken: Color(0xFFECEAE0),
    line: Color(0x1A3B4150), // rgba(59,65,80,.1)
    lineStrong: Color(0x333B4150), // .2
    ink: Color(0xFF2A2620),
    inkSoft: Color(0xFF5C5749),
    inkMute: Color(0xFF8A8474),
    inkTitle: Color(0xFF1F1B14),
    hairline: Color(0x241F1B14), // .14
    hairlineStrong: Color(0x481F1B14), // .28
  );

  @override
  UepSurface copyWith({
    Color? bg,
    Color? bgSoft,
    Color? bgCard,
    Color? bgSunken,
    Color? line,
    Color? lineStrong,
    Color? ink,
    Color? inkSoft,
    Color? inkMute,
    Color? inkTitle,
    Color? hairline,
    Color? hairlineStrong,
  }) {
    return UepSurface(
      bg: bg ?? this.bg,
      bgSoft: bgSoft ?? this.bgSoft,
      bgCard: bgCard ?? this.bgCard,
      bgSunken: bgSunken ?? this.bgSunken,
      line: line ?? this.line,
      lineStrong: lineStrong ?? this.lineStrong,
      ink: ink ?? this.ink,
      inkSoft: inkSoft ?? this.inkSoft,
      inkMute: inkMute ?? this.inkMute,
      inkTitle: inkTitle ?? this.inkTitle,
      hairline: hairline ?? this.hairline,
      hairlineStrong: hairlineStrong ?? this.hairlineStrong,
    );
  }

  @override
  UepSurface lerp(ThemeExtension<UepSurface>? other, double t) {
    if (other is! UepSurface) return this;
    Color l(Color a, Color b) => Color.lerp(a, b, t)!;
    return UepSurface(
      bg: l(bg, other.bg),
      bgSoft: l(bgSoft, other.bgSoft),
      bgCard: l(bgCard, other.bgCard),
      bgSunken: l(bgSunken, other.bgSunken),
      line: l(line, other.line),
      lineStrong: l(lineStrong, other.lineStrong),
      ink: l(ink, other.ink),
      inkSoft: l(inkSoft, other.inkSoft),
      inkMute: l(inkMute, other.inkMute),
      inkTitle: l(inkTitle, other.inkTitle),
      hairline: l(hairline, other.hairline),
      hairlineStrong: l(hairlineStrong, other.hairlineStrong),
    );
  }
}

/// 五 zone 色系。server 沒有 zone 欄位——UI 以 room id 的穩定雜湊指派，
/// 純粹是視覺點綴，同一房間永遠得到同一組色。
enum UepZone { history, echoes, visuals, concepts, storage }

@immutable
class ZonePalette {
  const ZonePalette({
    required this.main,
    required this.soft,
    required this.tintDark,
    required this.tintLight,
    required this.strokeDark,
    required this.strokeLight,
  });

  final Color main;
  final Color soft;
  final Color tintDark;
  final Color tintLight;
  final Color strokeDark;
  final Color strokeLight;

  Color tint(Brightness b) => b == Brightness.dark ? tintDark : tintLight;
  Color stroke(Brightness b) => b == Brightness.dark ? strokeDark : strokeLight;
}

const Map<UepZone, ZonePalette> uepZonePalettes = {
  UepZone.history: ZonePalette(
    main: Color(0xFF6B3F2A),
    soft: Color(0xFFC8A46A),
    tintDark: Color(0x40C8A46A),
    tintLight: Color(0xFFF3E6C8),
    strokeDark: Color(0xBFC8A46A),
    strokeLight: Color(0xD96B3F2A),
  ),
  UepZone.echoes: ZonePalette(
    main: Color(0xFF355C7D),
    soft: Color(0xFF6C5B7B),
    tintDark: Color(0x40F8B195),
    tintLight: Color(0xFFF8B195),
    strokeDark: Color(0xD96C5B7B),
    strokeLight: Color(0xD9355C7D),
  ),
  UepZone.visuals: ZonePalette(
    main: Color(0xFF5E548E),
    soft: Color(0xFF9F86C0),
    tintDark: Color(0x40E0B1CB),
    tintLight: Color(0xFFE0B1CB),
    strokeDark: Color(0xCC9F86C0),
    strokeLight: Color(0xD95E548E),
  ),
  UepZone.concepts: ZonePalette(
    main: Color(0xFF2D6A4F),
    soft: Color(0xFF74C69D),
    tintDark: Color(0x4074C69D),
    tintLight: Color(0xFFD8F3DC),
    strokeDark: Color(0xBF74C69D),
    strokeLight: Color(0xD92D6A4F),
  ),
  UepZone.storage: ZonePalette(
    main: Color(0xFFC4A00E),
    soft: Color(0xFFD5B618),
    tintDark: Color(0x40D5B618),
    tintLight: Color(0xFFF5F5F0),
    strokeDark: Color(0xA6D5B618),
    strokeLight: Color(0xB3C4A00E),
  ),
};

/// room id → zone 的穩定指派（FNV-1a 雜湊）。
UepZone zoneForRoomId(String roomId) {
  var h = 0x811c9dc5;
  for (final c in roomId.codeUnits) {
    h ^= c;
    h = (h * 0x01000193) & 0xFFFFFFFF;
  }
  return UepZone.values[h % UepZone.values.length];
}

extension UepThemeContext on BuildContext {
  UepSurface get uep => Theme.of(this).extension<UepSurface>()!;
}
