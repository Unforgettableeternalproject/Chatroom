import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../api/api_client.dart';
import '../../api/rooms_api.dart';
import '../../core/config/app_settings.dart';
import '../../core/errors/api_exception.dart';
import '../../core/theme/uep_theme.dart';
import '../../core/theme/uep_tokens.dart';
import '../../state/app_providers.dart';
import '../../state/notification_providers.dart';
import '../../widgets/kind_badge.dart';
import '../../widgets/uep_button.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  late final TextEditingController _urlController;
  late final TextEditingController _tokenController;
  late final TextEditingController _nameController;
  bool _showToken = false;
  String? _testResult;
  bool _testOk = false;
  bool _testing = false;
  bool _justSaved = false;

  @override
  void initState() {
    super.initState();
    final config = ref.read(appConfigProvider);
    _urlController = TextEditingController(text: config.serverUrl);
    _tokenController = TextEditingController(text: config.token);
    _nameController = TextEditingController(text: config.preferredName);
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
    _urlController.dispose();
    _tokenController.dispose();
    _nameController.dispose();
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
      setState(() {
        _testOk = true;
        _testResult =
            '連線成功 · hub ${health.version} · ${rooms.rooms.length} 個房間';
      });
    } on AuthException {
      setState(() {
        _testOk = false;
        _testResult = 'token 錯誤：伺服器拒絕了這組 API token';
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
        title: Text('重新產生裝置識別？',
            style: UepText.display(size: 22, color: context.uep.inkTitle)),
        content: Text(
          '所有房間會把你視為新成員，舊身分留在原房間的成員紀錄中。此操作無法復原。',
          style: UepText.serif(size: 13.5, color: context.uep.inkSoft),
        ),
        actions: [
          UepButton(
            label: '取消',
            variant: UepButtonVariant.outline,
            small: true,
            onPressed: () => Navigator.of(context).pop(false),
          ),
          UepButton(
            label: '重新產生',
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
        title: Text('設定', style: UepText.display(size: 22, color: s.inkTitle)),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: ListView(
            padding: const EdgeInsets.all(32),
            children: [
              MonoLabel('SERVER'),
              const SizedBox(height: 6),
              Text('連線設定',
                  style: UepText.display(size: 28, color: s.inkTitle)),
              const SizedBox(height: 22),
              _FieldLabel('HUB URL'),
              _box(
                context,
                TextField(
                  controller: _urlController,
                  style: UepText.code(size: 12.5, color: s.ink, height: 1.4),
                  decoration: _inputDecoration('http://127.0.0.1:8787', s),
                ),
              ),
              const SizedBox(height: 18),
              _FieldLabel('API TOKEN'),
              _box(
                context,
                TextField(
                  controller: _tokenController,
                  obscureText: !_showToken,
                  style: UepText.code(size: 12.5, color: s.ink, height: 1.4),
                  decoration: _inputDecoration('（未設定 token 的 Hub 可留空）', s)
                      .copyWith(
                    suffixIcon: IconButton(
                      icon: Icon(
                        _showToken
                            ? Icons.visibility_off_outlined
                            : Icons.visibility_outlined,
                        size: 16,
                        color: s.inkMute,
                      ),
                      onPressed: () =>
                          setState(() => _showToken = !_showToken),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 18),
              Row(children: [
                UepButton(
                  label: '測試連線',
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
                  label: '進入主畫面 →',
                  expand: true,
                  onPressed: () => context.go('/rooms'),
                ),
              ],
              const SizedBox(height: 26),
              Divider(color: s.line, height: 1),
              const SizedBox(height: 22),
              Row(children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('深色主題',
                          style: UepText.sans(size: 13.5, color: s.inkTitle)),
                      const SizedBox(height: 3),
                      Text('也可在標題列直接切換',
                          style:
                              UepText.serif(size: 12, color: s.inkMute)),
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
              const SizedBox(height: 22),
              Row(children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('系統通知',
                          style: UepText.sans(size: 13.5, color: s.inkTitle)),
                      const SizedBox(height: 3),
                      Text('已加入的聊天室有新訊息時',
                          style:
                              UepText.serif(size: 12, color: s.inkMute)),
                    ],
                  ),
                ),
                DropdownButton<NotifyModePref>(
                  value: ref.watch(settingsRepoProvider).notifyMode,
                  underline: const SizedBox.shrink(),
                  style: UepText.sans(size: 13, color: s.ink),
                  dropdownColor: s.bgCard,
                  items: const [
                    DropdownMenuItem(
                        value: NotifyModePref.all, child: Text('所有訊息')),
                    DropdownMenuItem(
                        value: NotifyModePref.mentions,
                        child: Text('僅提及我時')),
                    DropdownMenuItem(
                        value: NotifyModePref.off, child: Text('關閉')),
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
              const SizedBox(height: 22),
              _FieldLabel('顯示名稱（進房時的 PREFERRED NAME）'),
              _box(
                context,
                TextField(
                  controller: _nameController,
                  style: UepText.sans(size: 13, color: s.ink),
                  decoration:
                      _inputDecoration('留空則由 Hub 隨機指派代稱', s),
                  onSubmitted: (_) => _save(),
                ),
              ),
              const SizedBox(height: 20),
              Row(children: [
                UepButton(
                  label: '儲存設定',
                  small: true,
                  onPressed: _dirty ? _save : null,
                ),
                const SizedBox(width: 12),
                UepButton(
                  label: '復原',
                  variant: UepButtonVariant.outline,
                  small: true,
                  onPressed: _dirty ? _revert : null,
                ),
                const SizedBox(width: 14),
                if (_dirty)
                  Text('有尚未儲存的變更',
                      style: UepText.serif(
                          size: 12.5, color: UepColors.gold, height: 1.4))
                else if (_justSaved)
                  Text('✓ 已儲存',
                      style: UepText.serif(
                          size: 12.5, color: UepColors.success, height: 1.4)),
              ]),
              const SizedBox(height: 22),
              _FieldLabel('本機裝置識別'),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
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
                      await Clipboard.setData(
                          ClipboardData(text: config.deviceKey));
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('已複製裝置識別')));
                      }
                    },
                    child: MonoLabel('複製', size: 9),
                  ),
                  TextButton(
                    onPressed: _regenerateKey,
                    child: MonoLabel('重新產生',
                        size: 9, color: UepColors.errorText),
                  ),
                ]),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _box(BuildContext context, Widget child) {
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

  InputDecoration _inputDecoration(String hint, UepSurface s) =>
      InputDecoration(
        isDense: true,
        border: InputBorder.none,
        hintText: hint,
        hintStyle: UepText.serif(size: 12.5, color: s.inkMute),
        contentPadding: const EdgeInsets.symmetric(vertical: 10),
      );
}

class _FieldLabel extends StatelessWidget {
  const _FieldLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 7),
      child: MonoLabel(text, color: context.uep.inkSoft, letterSpacing: 1.4),
    );
  }
}
