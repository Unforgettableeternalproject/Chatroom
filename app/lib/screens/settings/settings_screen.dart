import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../api/api_client.dart';
import '../../api/rooms_api.dart';
import '../../core/config/app_settings.dart';
import '../../core/errors/api_exception.dart';
import '../../core/config/build_info.dart';
import '../../core/config/invite_code.dart';
import '../../core/theme/uep_theme.dart';
import '../../core/theme/uep_tokens.dart';
import '../../l10n/l10n.dart';
import '../../state/app_providers.dart';
import '../../core/logging/redacting_logger.dart';
import '../../notifications/codex_dispatcher.dart';
import '../../state/notification_providers.dart';
import '../../widgets/kind_badge.dart';
import '../../widgets/settings_form.dart';
import '../../widgets/invite_manager.dart';
import '../../widgets/uep_button.dart';
import '../../widgets/uep_tab_bar.dart';
import '../../ws/ws_client.dart';
import '../../ws/ws_protocol.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  late final TextEditingController _urlController;
  late final TextEditingController _tokenController;
  late final TextEditingController _nameController;
  late final TextEditingController _codexThreadController;
  bool _showToken = false;
  String? _testResult;
  bool _testOk = false;
  bool _testing = false;
  bool _justSaved = false;

  @override
  void initState() {
    super.initState();
    // 連線固定是第 0 頁：首次啟動被 redirect 進來的人還沒有任何設定，
    // 落在別的分頁等於要他自己找入口
    _tabController = TabController(length: 3, vsync: this)
      ..addListener(() => setState(() {}));
    final config = ref.read(appConfigProvider);
    _urlController = TextEditingController(text: config.serverUrl);
    _tokenController = TextEditingController(text: config.token);
    _nameController = TextEditingController(text: config.preferredName);
    _codexThreadController = TextEditingController(
        text: ref.read(settingsRepoProvider).codexDispatchThread);
    // 髒狀態驅動儲存/復原按鈕的啟用與提示
    for (final c in [_urlController, _tokenController, _nameController]) {
      c.addListener(() => setState(() => _justSaved = false));
    }
  }

  /// 欄位內容與已儲存設定是否有出入。
  bool get _dirty {
    final config = ref.read(appConfigProvider);
    return _urlController.text.trim() != config.serverUrl ||
        _tokenController.text.trim() != config.token ||
        _nameController.text.trim() != config.preferredName;
  }

  /// 套用一份邀請碼：一次填好網址與 token。
  ///
  /// 從剪貼簿讀而不是給一個輸入框——邀請碼是一長串沒有意義的字，手打會錯，
  /// 而它到使用者手上的方式本來就是「複製一段訊息」。
  Future<void> _pasteInvite() async {
    final raw = (await Clipboard.getData(Clipboard.kTextPlain))?.text ?? '';
    final invite = InviteCode.tryParse(raw);
    if (invite == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content:
                Text(AppLocalizations.of(context).settingsInviteNotFound)));
      }
      return;
    }
    setState(() {
      _urlController.text = invite.serverUrl;
      _tokenController.text = invite.token;
      _justSaved = false;
    });
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(AppLocalizations.of(context)
              .settingsInviteFilled(invite.serverUrl))));
    }
  }

  Future<void> _save() async {
    final notifier = ref.read(appConfigProvider.notifier);
    await notifier.setServer(
        url: _urlController.text.trim(), token: _tokenController.text.trim());
    await notifier.setPreferredName(_nameController.text);
    if (mounted) setState(() => _justSaved = true);
  }

  void _revert() {
    final config = ref.read(appConfigProvider);
    _urlController.text = config.serverUrl;
    _tokenController.text = config.token;
    _nameController.text = config.preferredName;
    setState(() {});
  }

  @override
  void dispose() {
    _tabController.dispose();
    _urlController.dispose();
    _tokenController.dispose();
    _nameController.dispose();
    _codexThreadController.dispose();
    super.dispose();
  }

  /// 只測試，不儲存——儲存是「儲存設定」按鈕的職責，
  /// 混在一起會讓人分不清設定到底套用了沒（驗收回饋）。
  Future<void> _testConnection() async {
    setState(() {
      _testing = true;
      _testResult = null;
    });
    final url = _urlController.text.trim();
    final token = _tokenController.text.trim();
    try {
      // 用當下輸入值建臨時 client（不等 provider 重建）
      final dio = createApiDio(baseUrl: url, token: token);
      final api = RoomsApi(dio);
      final health = await api.health();
      final rooms = await api.list();
      dio.close();

      // 🔴 **REST 通不代表連得上。**
      //
      // 這顆按鈕原本只打 REST，而 App 的即時通道走 WS——**兩條路徑的認證是
      // 分開實作的**，分歧過兩次：08-29 的 access_token、09-07 的人類憑證，
      // 兩次都是「REST 收、WS 不收」。
      //
      // 那種狀態下這顆按鈕會說「連線成功」，而 App 進去之後一直重連。
      // 使用者看到的是「設定明明是對的」——**假綠燈比沒有燈更貴**，
      // 因為它把人推離真正的原因。
      //
      // 所以這裡要走一次真的 WS 握手。成本是一個立刻關掉的連線。
      final wsError = await probeWebSocket(url, token);
      if (wsError != null) {
        setState(() {
          _testOk = false;
          _testResult = wsError;
        });
        return;
      }

      setState(() {
        _testOk = true;
        _testResult =
            L10n.current.settingsTestOk(health.version, rooms.rooms.length);
      });
    } on AuthException {
      setState(() {
        _testOk = false;
        _testResult = L10n.current.settingsTestTokenRejected;
      });
    } on ApiException catch (e) {
      setState(() {
        _testOk = false;
        _testResult = e.message;
      });
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  Future<void> _regenerateKey() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(AppLocalizations.of(context).settingsRegenerateKeyTitle,
            style: UepText.pageTitle(color: context.uep.inkTitle)),
        content: Text(
          AppLocalizations.of(context).settingsRegenerateKeyBody,
          style: UepText.serif(size: 13.5, color: context.uep.inkSoft),
        ),
        actions: [
          UepButton(
            label: AppLocalizations.of(context).commonCancel,
            variant: UepButtonVariant.outline,
            small: true,
            onPressed: () => Navigator.of(context).pop(false),
          ),
          UepButton(
            label: AppLocalizations.of(context).commonRegenerate,
            variant: UepButtonVariant.danger,
            small: true,
            onPressed: () => Navigator.of(context).pop(true),
          ),
        ],
      ),
    );
    if (confirmed ?? false) {
      await ref.read(appConfigProvider.notifier).regenerateDeviceKey();
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    final config = ref.watch(appConfigProvider);
    final l10n = AppLocalizations.of(context);

    return Scaffold(
      backgroundColor: s.bg,
      appBar: AppBar(
        backgroundColor: s.bgSoft,
        surfaceTintColor: Colors.transparent,
        shape: Border(bottom: BorderSide(color: s.line)),
        leading: context.canPop()
            ? IconButton(
                icon: Icon(Icons.arrow_back, size: 18, color: s.inkSoft),
                onPressed: () => context.pop(),
              )
            : null,
        title:
            Text(l10n.settingsTitle, style: UepText.pageTitle(color: s.inkTitle)),
        actions: [
          IconButton(
            tooltip: l10n.helpTooltip,
            icon: Icon(Icons.help_outline, size: 18, color: s.inkMute),
            onPressed: () => context.push('/help/settings'),
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: kPageMaxWidth),
          child: Column(
            children: [
              UepTabBar(
                controller: _tabController,
                labels: [
                  l10n.settingsTabConnection,
                  l10n.settingsTabVisual,
                  l10n.settingsTabPersonal,
                ],
              ),
              Expanded(
                child: TabBarView(
                  controller: _tabController,
                  children: [
                    _connectionTab(s, config),
                    _visualTab(s, config),
                    _personalTab(s, config),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ---------- 連線 ----------

  Widget _connectionTab(UepSurface s, AppConfig config) {
    final l10n = AppLocalizations.of(context);
    return ListView(
      padding: const EdgeInsets.all(32),
      children: [
        Text(l10n.connectionSectionTitle,
            style: UepText.pageTitle(color: s.inkTitle)),
        const SizedBox(height: 22),
        UepButton(
          label: l10n.settingsPasteInvite,
          small: true,
          variant: UepButtonVariant.outline,
          expand: true,
          onPressed: _pasteInvite,
        ),
        const SizedBox(height: 18),
        SettingsFieldLabel(l10n.fieldHubUrl),
        SettingsInputBox(
          child: TextField(
            controller: _urlController,
            style: UepText.code(size: 12.5, color: s.ink, height: 1.4),
            decoration: settingsInputDecoration('http://127.0.0.1:8787', s),
          ),
        ),
        const SizedBox(height: 18),
        SettingsFieldLabel(l10n.fieldApiToken),
        SettingsInputBox(
          child: TextField(
            controller: _tokenController,
            obscureText: !_showToken,
            style: UepText.code(size: 12.5, color: s.ink, height: 1.4),
            decoration:
                settingsInputDecoration(l10n.settingsTokenHint, s).copyWith(
              suffixIcon: IconButton(
                icon: Icon(
                  _showToken
                      ? Icons.visibility_off_outlined
                      : Icons.visibility_outlined,
                  size: 16,
                  color: s.inkMute,
                ),
                onPressed: () => setState(() => _showToken = !_showToken),
              ),
            ),
          ),
        ),
        const SizedBox(height: 18),
        _saveRow(s),
        const SizedBox(height: 18),
        Row(children: [
          UepButton(
            label: l10n.settingsTestConnection,
            small: true,
            variant: UepButtonVariant.outline,
            onPressed: _testing ? null : _testConnection,
          ),
          const SizedBox(width: 14),
          if (_testing)
            SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: UepColors.gold),
            )
          else if (_testResult != null)
            Expanded(
              child: Row(children: [
                Text(_testOk ? '✓ ' : '✕ ',
                    style: TextStyle(
                        fontSize: 12,
                        color: _testOk
                            ? UepColors.success
                            : UepColors.errorText)),
                Expanded(
                  child: Text(_testResult!,
                      style: UepText.serif(
                          size: 13, color: s.inkSoft, height: 1.5)),
                ),
              ]),
            ),
        ]),
        // 首次啟動經 redirect 進來時沒有返回鍵可用，
        // 設定完成後要有明確的出口，否則會被卡在這裡（驗收 A1）
        if (!context.canPop() && config.isConfigured) ...[
          const SizedBox(height: 18),
          UepButton(
            label: l10n.settingsEnterApp,
            expand: true,
            onPressed: () => context.go('/rooms'),
          ),
        ],
        const SizedBox(height: 26),
        Divider(color: s.line, height: 1),
        const SizedBox(height: 22),
        // 版本一定要在設定頁看得到：回報問題時要問的第一件事就是
        // 「你手上是哪一份」，而使用者得找得到那個字串才答得出來
        Row(children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l10n.settingsAppVersion,
                    style: UepText.sans(size: 13.5, color: s.inkTitle)),
                const SizedBox(height: 3),
                if (!BuildInfo.current.isKnown)
                  Text(
                    l10n.settingsNoVersionMark,
                    style:
                        UepText.serif(size: 12, color: s.inkMute, height: 1.7),
                  ),
              ],
            ),
          ),
          SelectableText(BuildInfo.current.label,
              style: UepText.code(size: 11, color: s.inkSoft)),
        ]),
        const SizedBox(height: 26),
        Divider(color: s.line, height: 1),
        const SizedBox(height: 22),
        const InviteManager(),
      ],
    );
  }

  // ---------- 視覺 ----------

  Widget _visualTab(UepSurface s, AppConfig config) {
    final l10n = AppLocalizations.of(context);
    return ListView(
      padding: const EdgeInsets.all(32),
      children: [
        Text(l10n.visualSectionTitle,
            style: UepText.pageTitle(color: s.inkTitle)),
        const SizedBox(height: 22),
        Row(children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l10n.darkThemeLabel,
                    style: UepText.sans(size: 13.5, color: s.inkTitle)),
                const SizedBox(height: 3),
                Text(l10n.darkThemeHint,
                    style: UepText.serif(size: 12, color: s.inkMute)),
              ],
            ),
          ),
          Switch(
            value: config.themeMode == ThemeModePref.dark,
            activeThumbColor: UepColors.gold,
            activeTrackColor: UepColors.gold.withValues(alpha: .28),
            onChanged: (v) => ref
                .read(appConfigProvider.notifier)
                .setThemeMode(v ? ThemeModePref.dark : ThemeModePref.light),
          ),
        ]),
        const SizedBox(height: 26),
        Divider(color: s.line, height: 1),
        const SizedBox(height: 22),
        Text(l10n.fontScaleLabel,
            style: UepText.sans(size: 13.5, color: s.inkTitle)),
        const SizedBox(height: 3),
        Text(l10n.fontScaleHint,
            style: UepText.serif(size: 12, color: s.inkMute)),
        const SizedBox(height: 12),
        Row(children: [
          for (final (scale, label) in [
            (FontScalePref.tiny, l10n.fontScaleTiny),
            (FontScalePref.small, l10n.fontScaleSmall),
            (FontScalePref.medium, l10n.fontScaleMedium),
            (FontScalePref.large, l10n.fontScaleLarge),
            (FontScalePref.xlarge, l10n.fontScaleXLarge),
          ]) ...[
            UepButton(
              label: label,
              small: true,
              variant: config.fontScale == scale
                  ? UepButtonVariant.gold
                  : UepButtonVariant.outline,
              onPressed: () =>
                  ref.read(appConfigProvider.notifier).setFontScale(scale),
            ),
            const SizedBox(width: 10),
          ],
        ]),
        const SizedBox(height: 26),
        Divider(color: s.line, height: 1),
        const SizedBox(height: 22),
        // 字體。每個選項用自己那套字渲染名稱——字體要看過才選得出來，
        // 列出名字等於要人先記住哪個是哪個
        Text(l10n.fontFamilyLabel,
            style: UepText.sans(size: 13.5, color: s.inkTitle)),
        const SizedBox(height: 3),
        Text(l10n.fontFamilyHint,
            style: UepText.serif(size: 12, color: s.inkMute)),
        const SizedBox(height: 12),
        Wrap(spacing: 10, runSpacing: 10, children: [
          for (final (pref, label) in [
            (FontFamilyPref.standard, l10n.fontFamilyStandard),
            (FontFamilyPref.iansui, l10n.fontFamilyIansui),
            (FontFamilyPref.openhuninn, l10n.fontFamilyOpenhuninn),
            (FontFamilyPref.chenyuluoyan, l10n.fontFamilyChenyuluoyan),
            (FontFamilyPref.glowsans, l10n.fontFamilyGlowsans),
          ])
            _fontFamilyChip(s, pref, label, config.fontFamily == pref),
        ]),
        const SizedBox(height: 26),
        Divider(color: s.line, height: 1),
        const SizedBox(height: 22),
        // 語言。選中即存（跟字級同一個手勢），沒有「套用」按鈕——
        // 整個 App 立刻換掉，看得到就是套用了
        Text(l10n.languageLabel,
            style: UepText.sans(size: 13.5, color: s.inkTitle)),
        const SizedBox(height: 3),
        Text(l10n.languageHint,
            style: UepText.serif(size: 12, color: s.inkMute)),
        const SizedBox(height: 12),
        Row(children: [
          for (final (pref, label) in [
            (LocalePref.system, l10n.languageSystem),
            (LocalePref.zhTW, l10n.languageZhTW),
            (LocalePref.en, l10n.languageEnglish),
          ]) ...[
            UepButton(
              label: label,
              small: true,
              variant: config.locale == pref
                  ? UepButtonVariant.gold
                  : UepButtonVariant.outline,
              onPressed: () =>
                  ref.read(appConfigProvider.notifier).setLocale(pref),
            ),
            const SizedBox(width: 10),
          ],
        ]),
        const SizedBox(height: 26),
      ],
    );
  }

  // ---------- 個人化 ----------

  Widget _personalTab(UepSurface s, AppConfig config) {
    final l10n = AppLocalizations.of(context);
    return ListView(
      padding: const EdgeInsets.all(32),
      children: [
        Text(l10n.personalSectionTitle,
            style: UepText.pageTitle(color: s.inkTitle)),
        const SizedBox(height: 22),
        SettingsFieldLabel(l10n.fieldDisplayName),
        SettingsInputBox(
          child: TextField(
            controller: _nameController,
            style: UepText.sans(size: 13, color: s.ink),
            decoration: settingsInputDecoration(l10n.settingsDisplayNameHint, s),
            onSubmitted: (_) => _save(),
          ),
        ),
        const SizedBox(height: 20),
        _saveRow(s),
        const SizedBox(height: 22),
        SettingsFieldLabel(l10n.fieldDeviceKey),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          decoration: BoxDecoration(
            color: s.bgSoft,
            border: Border.all(color: s.line),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(children: [
            Expanded(
              child: Text(
                config.deviceKey,
                overflow: TextOverflow.ellipsis,
                style: UepText.code(size: 11, color: s.inkSoft),
              ),
            ),
            TextButton(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: config.deviceKey));
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                      content: Text(l10n.settingsDeviceKeyCopied)));
                }
              },
              child: MonoLabel(l10n.commonCopy, size: 9),
            ),
            TextButton(
              onPressed: _regenerateKey,
              child: MonoLabel(l10n.commonRegenerate,
                  size: 9, color: UepColors.errorText),
            ),
          ]),
        ),
        const SizedBox(height: 26),
        Divider(color: s.line, height: 1),
        const SizedBox(height: 22),
        Row(children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l10n.settingsNotifyLabel,
                    style: UepText.sans(size: 13.5, color: s.inkTitle)),
                const SizedBox(height: 3),
                Text(l10n.settingsNotifyHint,
                    style: UepText.serif(size: 12, color: s.inkMute)),
              ],
            ),
          ),
          DropdownButton<NotifyModePref>(
            value: ref.watch(settingsRepoProvider).notifyMode,
            underline: const SizedBox.shrink(),
            style: UepText.sans(size: 13, color: s.ink),
            dropdownColor: s.bgCard,
            items: [
              DropdownMenuItem(
                  value: NotifyModePref.all,
                  child: Text(l10n.settingsNotifyAll)),
              DropdownMenuItem(
                  value: NotifyModePref.mentions,
                  child: Text(l10n.settingsNotifyMentions)),
              DropdownMenuItem(
                  value: NotifyModePref.off,
                  child: Text(l10n.settingsNotifyOff)),
            ],
            onChanged: (v) async {
              if (v == null) return;
              await ref.read(settingsRepoProvider).setNotifyMode(v);
              // 通知中心即時吃到新模式，不必重啟 app
              ref.read(notificationCenterProvider).mode = v;
              setState(() {});
            },
          ),
        ]),
        if (ref.watch(closeToTraySupportedProvider)) ...[
          const SizedBox(height: 22),
          Row(children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(l10n.settingsCloseToTrayLabel,
                      style: UepText.sans(size: 13.5, color: s.inkTitle)),
                  const SizedBox(height: 3),
                  Text(l10n.settingsCloseToTrayHint,
                      style: UepText.serif(size: 12, color: s.inkMute)),
                ],
              ),
            ),
            Switch(
              value: config.closeToTray,
              activeThumbColor: UepColors.gold,
              activeTrackColor: UepColors.gold.withValues(alpha: .28),
              onChanged: (v) =>
                  ref.read(appConfigProvider.notifier).setCloseToTray(v),
            ),
          ]),
        ],
        if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) ...[
          const SizedBox(height: 22),
          Row(children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(l10n.settingsCodexForwardLabel,
                      style: UepText.sans(size: 13.5, color: s.inkTitle)),
                  const SizedBox(height: 3),
                  Text(l10n.settingsCodexForwardHint,
                      style: UepText.serif(size: 12, color: s.inkMute)),
                ],
              ),
            ),
            Switch(
              value: ref.watch(settingsRepoProvider).codexDispatchEnabled,
              activeThumbColor: UepColors.gold,
              activeTrackColor: UepColors.gold.withValues(alpha: .28),
              onChanged: (v) async {
                await ref.read(settingsRepoProvider).setCodexDispatchEnabled(v);
                ref.read(codexDispatcherProvider).enabled = v;
                setState(() {});
              },
            ),
          ]),
          if (ref.watch(settingsRepoProvider).codexDispatchEnabled) ...[
            const SizedBox(height: 8),
            SettingsInputBox(
              child: TextField(
                controller: _codexThreadController,
                style: UepText.sans(size: 13, color: s.ink),
                decoration: settingsInputDecoration(l10n.settingsCodexThreadHint, s),
                onSubmitted: (v) async {
                  await ref
                      .read(settingsRepoProvider)
                      .setCodexDispatchThread(v);
                  ref.read(codexDispatcherProvider).threadOverride = v.trim();
                },
              ),
            ),
            const SizedBox(height: 10),
            _CodexDispatchStatusView(ref.read(codexDispatcherProvider)),
          ],
        ],
      ],
    );
  }

  /// 字體選項鈕。UepButton 一律 mono ＋ 全大寫，這裡要的是預覽，
  /// 所以照它 small 的規格（padding、圓角、邊框、選中配色）自己畫一顆，
  /// 只換掉字。
  ///
  /// 行高用字級那排的 strut 鎖住（`forceStrutHeight`）：中文字體的 metrics
  /// 各不相同，不鎖的話這排會比字級那排高，而且每換一個字體高度都在跳。
  Widget _fontFamilyChip(
      UepSurface s, FontFamilyPref pref, String label, bool selected) {
    final name = UepText.familyName(pref);
    final color = selected ? UepColors.goldInkOn : s.inkSoft;
    // 字面大小各家差很多：辰宇落雁體是手寫細體、Glow Sans 是壓縮體，
    // 照同一個 fontSize 排會一大一小。只動字級不動行高，整排不會被撐高
    final size = switch (pref) {
      FontFamilyPref.chenyuluoyan => 14.0,
      FontFamilyPref.glowsans => 13.0,
      _ => 12.5,
    };
    final base = name == null
        ? GoogleFonts.notoSerifTc(fontSize: size, color: color)
        : TextStyle(fontFamily: name, fontSize: size, color: color);
    // 字級 chip 的字：UepButton small 用 mono(10.5, w500, ls 1.6)
    final ruler = UepText.mono(size: 10.5, weight: FontWeight.w500);
    final child = Text(
      label,
      style: base.copyWith(
        fontFamilyFallback: name == null ? null : UepText.sansFallback,
      ),
      strutStyle: StrutStyle.fromTextStyle(ruler, forceStrutHeight: true),
    );
    final pad = const EdgeInsets.symmetric(horizontal: 18, vertical: 10);
    final shape =
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(999));
    return selected
        ? FilledButton(
            onPressed: () =>
                ref.read(appConfigProvider.notifier).setFontFamily(pref),
            style: FilledButton.styleFrom(
              backgroundColor: UepColors.gold,
              foregroundColor: UepColors.goldInkOn,
              padding: pad,
              shape: shape,
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: child,
          )
        : OutlinedButton(
            onPressed: () =>
                ref.read(appConfigProvider.notifier).setFontFamily(pref),
            style: OutlinedButton.styleFrom(
              side: BorderSide(color: s.lineStrong),
              foregroundColor: s.inkSoft,
              padding: pad,
              shape: shape,
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: child,
          );
  }

  /// 儲存／復原：欄位散在連線與個人化兩頁，兩頁都要有同一組出口
  /// （`_save` 本來就一次寫三個欄位）。
  Widget _saveRow(UepSurface s) {
    final l10n = AppLocalizations.of(context);
    return Row(children: [
      UepButton(
        label: l10n.settingsSaveButton,
        small: true,
        onPressed: _dirty ? _save : null,
      ),
      const SizedBox(width: 12),
      UepButton(
        label: l10n.settingsRevertButton,
        variant: UepButtonVariant.outline,
        small: true,
        onPressed: _dirty ? _revert : null,
      ),
      const SizedBox(width: 14),
      if (_dirty)
        Text(l10n.settingsUnsavedChanges,
            style:
                UepText.serif(size: 12.5, color: UepColors.gold, height: 1.4))
      else if (_justSaved)
        Text(l10n.settingsSaved,
            style: UepText.serif(
                size: 12.5, color: UepColors.success, height: 1.4)),
    ]);
  }
}

/// 走一次真的 WS 握手。通了回 null，不通回一句給人看的話。
///
/// 🔴 **這是「測試連線」不再說謊的那一半。** 那顆按鈕原本只打 REST，而
/// App 的即時通道走 WS——兩條路徑的認證是分開實作的，分歧過兩次
/// （08-29 的 access_token、09-07 的人類憑證），兩次都是「REST 收、WS 不收」。
/// 那種狀態下按鈕會說「連線成功」，而 App 進去之後一直重連。
///
/// ⚠️ **訊息要講「REST 通了但 WS 不通」而不是「連線失敗」**——後者會讓人
/// 回去檢查網址與 token，而那兩樣剛剛才被證明是對的。把人送去查一個已經
/// 排除掉的方向，比不講還糟。
///
/// `connector` 只為了測試而存在：真的開 socket 的話這條驗不了。
Future<String?> probeWebSocket(
  String url,
  String token, {
  WsConnector connector = defaultWsConnector,
  Duration timeout = const Duration(seconds: 8),
}) async {
  try {
    final conn = await connector(WsProtocol.wsUri(url, token)).timeout(timeout);
    await conn.close();
    return null;
  } on TimeoutException {
    return L10n.current.settingsWsTimeout(timeout.inSeconds);
  } on Object catch (e) {
    // 4401 是 Hub 明確拒絕這張憑證。它與「網路不通」是完全不同的處置，
    // 所以要分開講
    final text = '$e';
    final rejected = text.contains('4401') || text.contains('403');
    return rejected
        ? L10n.current.settingsWsRejected
        : L10n.current.settingsWsFailed('$e');
  }
}


/// Codex 轉送的當下狀態。
///
/// 這條管線的失敗形狀全是靜默的：投不出去就留在記憶體等補投，畫面上一切
/// 正常。09/12 追「@ 了 Codex 卻沒醒」時，能回答「現在到底有沒有東西卡著」
/// 的只有一個測試才看得到的欄位——結論只能靠推理，沒辦法當場看一眼。
class _CodexDispatchStatusView extends StatelessWidget {
  const _CodexDispatchStatusView(this.dispatcher);

  final CodexDispatcher dispatcher;

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    return ValueListenableBuilder<CodexDispatchStatus>(
      valueListenable: dispatcher.status,
      builder: (context, st, _) {
        final l10n = AppLocalizations.of(context);
        final lines = <String>[
          st.busyThreads > 0
              ? l10n.settingsCodexThreadsBusy(st.localThreads, st.busyThreads)
              : l10n.settingsCodexThreadsIdle(st.localThreads),
          // 30 分鐘 / 50 則是 codex_dispatcher.dart 的 `_pendingTtl` 與
          // `_pendingLimit`（兩者都是 private，跨檔取不到，只能硬編）；
          // 10 秒是 notification_providers.dart 的補投輪詢週期。
          st.pending > 0
              ? l10n.settingsCodexPending(st.pending)
              : l10n.settingsCodexPendingNone,
          if (st.lastEvent.isNotEmpty)
            l10n.settingsCodexLastEvent(st.lastEvent),
        ];
        return Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: s.inkMute.withValues(alpha: .06),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: s.inkMute.withValues(alpha: .18)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final line in lines) ...[
                Text(line, style: UepText.serif(size: 12, color: s.inkMute)),
                const SizedBox(height: 3),
              ],
              const SizedBox(height: 3),
              SelectableText(
                l10n.settingsCodexLogPath(
                    logFile?.path ?? l10n.settingsCodexLogNone),
                style: UepText.mono(size: 10.5, color: s.inkMute),
              ),
            ],
          ),
        );
      },
    );
  }
}
