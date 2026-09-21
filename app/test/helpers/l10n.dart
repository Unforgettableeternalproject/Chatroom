import 'package:flutter/widgets.dart';

import 'package:chatroom_app/l10n/app_localizations.dart';

/// 測試裡的 `MaterialApp` 掛這兩個，畫面上 `AppLocalizations.of(context)`
/// 才拿得到字（getter 不可為 null，沒掛會直接炸）。預設 locale 是繁中，
/// 既有以中文比對的斷言不用改。
const kTestLocalizationsDelegates = AppLocalizations.localizationsDelegates;
/// 只列繁中：flutter test 的平台 locale 是 en_US，若把 en 也列進去，沒指定
/// `locale:` 的測試會整個變英文，中文斷言全滅。要測其他語言的測試自己給
/// `locale:` 與完整的 supportedLocales（見 settings_locale_test）。
const kTestSupportedLocales = <Locale>[Locale('zh', 'TW')];
const kTestLocale = Locale('zh', 'TW');
