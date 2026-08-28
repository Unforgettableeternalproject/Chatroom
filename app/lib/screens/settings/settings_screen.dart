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

  @override
  void initState() {
    super.initState();
    final config = ref.read(appConfigProvider);
    _urlController = TextEditingController(text: config.serverUrl);
    _tokenController = TextEditingController(text: config.token);
    _nameController = TextEditingController(text: config.preferredName);
  }

  @override
  void dispose() {
    _urlController.dispose();
    _tokenController.dispose();
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _saveAndTest() async {
    setState(() {
      _testing = true;
      _testResult = null;
    });
    final url = _urlController.text.trim();
    final token = _tokenController.text.trim();
    await ref
        .read(appConfigProvider.notifier)
        .setServer(url: url, token: token);
    await ref.read(appConfigProvider.notifier)
        .setPreferredName(_nameController.text);
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
                  onPressed: _testing ? null : _saveAndTest,
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
              _FieldLabel('顯示名稱（進房時的 PREFERRED NAME）'),
              _box(
                context,
                TextField(
                  controller: _nameController,
                  style: UepText.sans(size: 13, color: s.ink),
                  decoration:
                      _inputDecoration('留空則由 Hub 隨機指派代稱', s),
                  onSubmitted: (v) => ref
                      .read(appConfigProvider.notifier)
                      .setPreferredName(v),
                ),
              ),
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
