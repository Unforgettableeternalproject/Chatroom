import 'package:chatroom_app/core/config/app_settings.dart';
import 'package:chatroom_app/core/theme/uep_theme.dart';
import 'package:chatroom_app/state/app_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 字體偏好落盤、快照同步，以及套到 UepText 之後哪些字會換。
///
/// mono 要一起驗：程式碼與 seq 靠等寬對齊，換成中文字體會散掉——
/// 「serif 換了」本身證明不了 mono 沒被順手換掉。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SettingsRepository settings;

  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    settings = SettingsRepository(await SharedPreferences.getInstance());
    UepText.family = FontFamilyPref.standard;
  });

  tearDown(() => UepText.family = FontFamilyPref.standard);

  test('沒設定過時是預設字體', () {
    expect(settings.fontFamily, FontFamilyPref.standard);
  });

  test('寫進去的值會落盤，key 是 chatroom.font_family', () async {
    await settings.setFontFamily(FontFamilyPref.iansui);

    expect(settings.fontFamily, FontFamilyPref.iansui);
    expect(settings.prefs.getString('chatroom.font_family'), 'iansui');
  });

  test('prefs 裡是壞值時回預設，不丟例外', () async {
    SharedPreferences.setMockInitialValues(
        {'chatroom.font_family': 'comic-sans'});
    final repo = SettingsRepository(await SharedPreferences.getInstance());

    expect(repo.fontFamily, FontFamilyPref.standard);
  });

  test('setFontFamily 同步快照，重建時從 prefs 讀回來', () async {
    final container = ProviderContainer(overrides: [
      settingsRepoProvider.overrideWithValue(settings),
      initialConfigProvider.overrideWithValue(
        AppConfig.fromSettings(settings, token: '', deviceKey: 'dev-1'),
      ),
    ]);
    addTearDown(container.dispose);

    expect(container.read(appConfigProvider).fontFamily,
        FontFamilyPref.standard);

    await container
        .read(appConfigProvider.notifier)
        .setFontFamily(FontFamilyPref.glowsans);
    expect(container.read(appConfigProvider).fontFamily,
        FontFamilyPref.glowsans);

    // 下次啟動走的是這條路：快照由倉庫重建
    expect(
        AppConfig.fromSettings(settings, token: '', deviceKey: 'dev-1')
            .fontFamily,
        FontFamilyPref.glowsans);
  });

  test('每個選項對到 pubspec 宣告的家族名，預設沒有自訂家族', () {
    expect(UepText.familyName(FontFamilyPref.standard), isNull);
    expect(UepText.familyName(FontFamilyPref.iansui), 'Iansui');
    expect(UepText.familyName(FontFamilyPref.openhuninn), 'jf-openhuninn');
    expect(UepText.familyName(FontFamilyPref.chenyuluoyan), 'ChenYuluoyan');
    expect(UepText.familyName(FontFamilyPref.glowsans), 'GlowSansTC');
  });

  test('預設時 serif 與 display 維持 google_fonts 那套', () {
    // google_fonts 的家族名帶字重後綴（CormorantGaramond_600），比前綴
    expect(UepText.serif().fontFamily, startsWith('NotoSerifTC'));
    expect(UepText.pageTitle().fontFamily, startsWith('CormorantGaramond'));
  });

  test('選了字體後 serif／display 換家族，且補 Noto Serif TC fallback', () {
    UepText.family = FontFamilyPref.chenyuluoyan;

    final serif = UepText.serif(size: 15);
    expect(serif.fontFamily, 'ChenYuluoyan');
    expect(serif.fontSize, 15);
    expect(serif.fontFamilyFallback,
        contains(GoogleFonts.notoSerifTc().fontFamily));

    expect(UepText.pageTitle().fontFamily, 'ChenYuluoyan');
  });

  test('選了字體後 sans 也換家族，fallback 先 Inter 再 Noto Serif TC', () {
    expect(UepText.sans().fontFamily, startsWith('Inter'));

    UepText.family = FontFamilyPref.openhuninn;

    final sans = UepText.sans(size: 14.5);
    expect(sans.fontFamily, 'jf-openhuninn');
    expect(sans.fontSize, 14.5);
    // 拉丁字母要退回 Inter，不然西文會變成中文字體附的那套
    expect(sans.fontFamilyFallback!.first, startsWith('Inter'));
    expect(sans.fontFamilyFallback!.last, startsWith('NotoSerifTC'));
  });

  test('ThemeData 的預設字族也跟著換——沒經過 UepText 的 Text 靠它', () {
    expect(buildUepTheme(Brightness.dark).textTheme.bodyMedium?.fontFamily,
        startsWith('Inter'));

    UepText.family = FontFamilyPref.iansui;

    expect(buildUepTheme(Brightness.dark).textTheme.bodyMedium?.fontFamily,
        'Iansui');
  });

  test('mono 與 code 的 primary 永遠是 JetBrains Mono', () {
    final monoBefore = UepText.mono().fontFamily;
    final codeBefore = UepText.code().fontFamily;

    UepText.family = FontFamilyPref.glowsans;

    expect(UepText.mono().fontFamily, monoBefore);
    expect(UepText.code().fontFamily, codeBefore);
    expect(monoBefore, startsWith('JetBrainsMono'));
  });

  test('預設時 mono 的 fallback 不含任何自訂字族', () {
    final fallback = UepText.mono().fontFamilyFallback ?? const <String>[];

    for (final pref in FontFamilyPref.values) {
      final name = UepText.familyName(pref);
      if (name != null) expect(fallback, isNot(contains(name)));
    }
  });

  test('選了字體後 mono／code 的中文落到自訂字族，拉丁與數字不變', () {
    UepText.family = FontFamilyPref.iansui;

    // primary 沒有 CJK，中文自然往下找——第一個就是選的那套
    for (final style in [UepText.mono(), UepText.code(), UepText.label(),
        UepText.fieldLabel()]) {
      expect(style.fontFamily, startsWith('JetBrainsMono'));
      expect(style.fontFamilyFallback!.first, 'Iansui');
      expect(style.fontFamilyFallback!, contains(
          GoogleFonts.notoSerifTc().fontFamily));
    }
  });
}
