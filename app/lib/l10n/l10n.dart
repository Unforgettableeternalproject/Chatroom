import 'package:flutter/widgets.dart';

import 'app_localizations.dart';

export 'app_localizations.dart';

/// 沒有 `BuildContext` 的地方（模型的顯示文字、API 例外訊息、系統通知、
/// WebSocket 服務）拿翻譯用的入口。
///
/// 有 context 的 widget **一律用 `AppLocalizations.of(context)`**，這裡只是
/// 給拿不到 context 的程式碼的退路——它跟著 `MaterialApp` 的 locale 走
/// （`L10nSync` 在每次 build 同步），但不會觸發 rebuild。
///
/// 預設是繁中：測試裡沒掛 `L10nSync` 時，字串就是 ARB 模板那份。
class L10n {
  L10n._();

  static AppLocalizations current =
      lookupAppLocalizations(const Locale('zh', 'TW'));

  /// 同步到指定 locale；不在 supportedLocales 裡就退回繁中。
  static void use(Locale locale) {
    current = lookupAppLocalizations(_supported(locale)
        ? locale
        : const Locale('zh', 'TW'));
  }

  static bool _supported(Locale locale) => AppLocalizations.supportedLocales
      .any((l) => l.languageCode == locale.languageCode);
}

/// 掛在 `MaterialApp.builder` 底下：每次 locale 變了，`L10n.current`
/// 就跟著換。子樹照常拿 `AppLocalizations.of(context)`。
class L10nSync extends StatelessWidget {
  const L10nSync({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    L10n.current = AppLocalizations.of(context);
    return child;
  }
}
