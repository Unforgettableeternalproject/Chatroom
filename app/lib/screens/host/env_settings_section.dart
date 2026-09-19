/// 「這台機器」的設定區：Hub 的 `.env` 與 agent 接入的 `.env`。
///
/// ## 這裡不是 `.env` 的鏡像
///
/// 早一版把檔案裡的每個 key 都排出來、標籤直接寫變數名。那是給寫檔案的人
/// 看的東西，不是給用這個 App 的人看的——畫面上於是出現一堆只有讀過
/// `config.py` 才知道要填什麼的欄位。
///
/// 現在只留**會有人想改的那幾個**，標籤講人話，變數名縮到欄位底下那行小字
/// （對得上自己檔案裡的那一行就夠了），其餘收進「進階」。改不得的（token）
/// 是唯讀＋複製，換它走 `scripts/rotate-token.py`。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/uep_theme.dart';
import '../../core/theme/uep_tokens.dart';
import '../../core/util/env_file.dart';
import '../../l10n/l10n.dart';
import '../../models/host_kit.dart';
import '../../state/host_actions.dart';
import '../../state/host_kit_providers.dart';
import '../../state/host_probe.dart';
import '../../state/mcp_kit_providers.dart';
import '../../widgets/uep_button.dart';


/// `.env` 一個欄位的規格。
enum _EnvKind { text, port, minutes, nonNegInt, url, choice }

class _EnvFieldSpec {
  const _EnvFieldSpec(
    this.key,
    this.label, {
    this.kind = _EnvKind.text,
    this.secret = false,
    this.options = const [],
  });

  /// `.env` 裡的變數名。標籤之外，它只出現在欄位底下的小字裡。
  final String key;

  /// 給人看的標籤。
  final String Function(AppLocalizations l10n) label;

  final _EnvKind kind;

  /// 遮罩顯示，可按眼睛看。
  final bool secret;

  /// `choice` 用的選項，第一項是空字串（沒設，用預設值）。
  final List<String> options;
}

/// Hub 常改的那幾個。
///
/// `CHATROOM_TOKEN` 不在這裡——它在同一區用唯讀的方式顯示。
/// `CHATROOM_DB`／`CHATROOM_HUMAN_TOKEN`／`CHATROOM_TUNNEL_URL_FILE` 也不在：
/// 那三個是安裝時決定的，改錯的代價（資料庫換成一個空的、主持人把自己鎖在
/// 外面）遠大於在這頁改它的方便。
final _hubFields = <_EnvFieldSpec>[
  _EnvFieldSpec('CHATROOM_HOST', (l) => l.hostEnvLabelBind),
  _EnvFieldSpec('CHATROOM_PORT', (l) => l.hostEnvLabelPort,
      kind: _EnvKind.port),
  // 檔案裡是秒，畫面上是分鐘——600 秒這種值沒有人在心裡換算
  _EnvFieldSpec('CHATROOM_IDLE_TIMEOUT', (l) => l.hostEnvLabelIdle,
      kind: _EnvKind.minutes),
  _EnvFieldSpec('CHATROOM_PURGE_ARCHIVED_DAYS', (l) => l.hostEnvLabelPurge,
      kind: _EnvKind.nonNegInt),
  _EnvFieldSpec('CHATROOM_RUN_DAILY_QUOTA', (l) => l.hostEnvLabelQuota,
      kind: _EnvKind.nonNegInt),
  _EnvFieldSpec('CHATROOM_RUN_QUEUE_CAP', (l) => l.hostEnvLabelQueueCap,
      kind: _EnvKind.nonNegInt),
];

/// Hub 的進階：多數主持人一輩子不會碰。
final _hubAdvancedFields = <_EnvFieldSpec>[
  _EnvFieldSpec('CHATROOM_ATTACHMENT_DIR', (l) => l.hostEnvLabelAttachmentDir),
  _EnvFieldSpec('CHATROOM_LOG_LEVEL', (l) => l.hostEnvLabelLogLevel,
      kind: _EnvKind.choice,
      options: const ['', 'DEBUG', 'INFO', 'WARNING', 'ERROR']),
  _EnvFieldSpec(
      'CHATROOM_SUBAGENT_TIMEOUT', (l) => l.hostEnvLabelSubagentTimeout,
      kind: _EnvKind.nonNegInt),
  _EnvFieldSpec('CHATROOM_HOLD_MAX', (l) => l.hostEnvLabelHoldMax,
      kind: _EnvKind.nonNegInt),
];

/// agent 接入要填的三件事：叫什麼、連去哪、拿哪把鑰匙。
final _mcpFields = <_EnvFieldSpec>[
  _EnvFieldSpec('CHATROOM_DEFAULT_NAME', (l) => l.hostEnvLabelDefaultName),
  _EnvFieldSpec('CHATROOM_URL', (l) => l.fieldHubUrl, kind: _EnvKind.url),
  _EnvFieldSpec('CHATROOM_TOKEN', (l) => l.hostEnvLabelAgentToken,
      secret: true),
];

final _mcpAdvancedFields = <_EnvFieldSpec>[
  _EnvFieldSpec('CHATROOM_AGENT_KIND', (l) => l.hostEnvLabelAgentKind),
  _EnvFieldSpec('CHATROOM_HOST_NAME', (l) => l.hostEnvLabelHostName),
  _EnvFieldSpec('CHATROOM_STATE_TTL_DAYS', (l) => l.hostEnvLabelStateTtl,
      kind: _EnvKind.nonNegInt),
];

/// 兩邊讀到的是同一個檔案時，agent 這邊只留**只有 agent 會用到**的那幾個
/// key。位址與 token 是 Hub 那份設定的欄位，在兩個區塊各出現一次的話，
/// 先存的那次會被後存的那次蓋回去。
final _mcpSharedFields = <_EnvFieldSpec>[
  _EnvFieldSpec('CHATROOM_DEFAULT_NAME', (l) => l.hostEnvLabelDefaultName),
  _EnvFieldSpec('CHATROOM_AGENT_KIND', (l) => l.hostEnvLabelAgentKind),
  _EnvFieldSpec('CHATROOM_HOST_NAME', (l) => l.hostEnvLabelHostName),
];

/// 是同一個檔案嗎。Windows 的路徑大小寫不分，分隔符也可能兩種都出現。
bool sameEnvFile(String a, String b) {
  if (a.isEmpty || b.isEmpty) return false;
  String norm(String p) {
    final t = p.replaceAll(r'\', '/');
    return Platform.isWindows ? t.toLowerCase() : t;
  }

  return norm(a) == norm(b);
}

/// Hub 分頁的設定區。緊接在起停那一區後面——改完要重啟才生效。
class HubEnvSection extends ConsumerWidget {
  const HubEnvSection({super.key, required this.kit});

  final HostKit kit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final values = ref.watch(hostEnvRawProvider);

    return _panelOr(
      context,
      title: l10n.hostEnvPanelHubSettings,
      values: values,
      emptyText: l10n.hostEnvUnreadable,
      builder: (map) => _EnvEditor(
        key: ValueKey('hub:${kit.envFile}'),
        title: l10n.hostEnvPanelHubSettings,
        path: kit.envFile,
        fields: _hubFields,
        advanced: _hubAdvancedFields,
        values: map,
        readOnlyToken: map['CHATROOM_TOKEN'] ?? '',
        savedMessage: l10n.hostEnvSavedRestartHub,
        offerRestart: true,
        onSaved: (ref) {
          ref.invalidate(hostEnvProvider);
          ref.invalidate(hostEnvRawProvider);
        },
      ),
    );
  }
}

/// 成員分頁的設定區：這台機器的 agent 怎麼接上 Hub。
class McpEnvSection extends ConsumerWidget {
  const McpEnvSection({super.key, required this.kit});

  final McpKit kit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final values = ref.watch(mcpEnvRawProvider);
    // 本機來源模式讀到的多半就是 Hub 自己那份 `server/.env`
    final hostKit = ref.watch(hostKitProvider).value;
    final shared = hostKit != null && sameEnvFile(kit.envFile, hostKit.envFile);

    return _panelOr(
      context,
      title: l10n.hostEnvPanelMcpSettings,
      values: values,
      emptyText: l10n.hostMcpEnvMissing,
      builder: (map) => _EnvEditor(
        key: ValueKey('mcp:${kit.envFile}:$shared'),
        title: l10n.hostEnvPanelMcpSettings,
        path: kit.envFile,
        fields: shared ? _mcpSharedFields : _mcpFields,
        advanced: shared ? const [] : _mcpAdvancedFields,
        values: map,
        note: shared ? l10n.hostEnvSharedFile : null,
        savedMessage: l10n.hostEnvSavedNextConnect,
        onSaved: (ref) {
          ref.invalidate(mcpEnvProvider);
          ref.invalidate(mcpEnvRawProvider);
          ref.invalidate(mcpStatusProvider);
        },
      ),
    );
  }
}

/// 讀檔還沒好／讀不到時的那一格，與本頁其他區塊同一個排法。
Widget _panelOr(
  BuildContext context, {
  required String title,
  required AsyncValue<Map<String, String>?> values,
  required String emptyText,
  required Widget Function(Map<String, String> map) builder,
}) {
  final s = context.uep;
  Widget line(String text) =>
      Text(text, style: UepText.serif(size: 14, color: s.inkMute));

  return values.when(
    loading: () => _Panel(
        title: title,
        child: line(AppLocalizations.of(context).hostKitInstallChecking)),
    error: (e, _) => _Panel(title: title, child: line('$e')),
    data: (map) => map == null
        ? _Panel(title: title, child: line(emptyText))
        : builder(map),
  );
}

/// 兩個分頁共用的表單。
///
/// 寫回走 `writeEnvUpdates()`：**只覆寫改過的那幾個 key**，其餘行、註解與
/// 順序原樣保留（規則與 `host-kit/install.py:update_env()` 同一套）。
///
/// 「改過」的判準是欄位上的字與讀進來那一刻不同——沒碰過的欄位既不驗證
/// 也不寫回，所以存一次檔不會在檔案裡多出一堆空的 `KEY=`，也不會因為
/// 檔案裡手寫的秒數換算不回整分而卡住整張表單。
class _EnvEditor extends ConsumerStatefulWidget {
  const _EnvEditor({
    super.key,
    required this.title,
    required this.path,
    required this.fields,
    required this.advanced,
    required this.values,
    required this.savedMessage,
    required this.onSaved,
    this.note,
    this.readOnlyToken,
    this.offerRestart = false,
  });

  final String title;
  final String path;
  final List<_EnvFieldSpec> fields;
  final List<_EnvFieldSpec> advanced;
  final Map<String, String> values;

  /// 欄位上方的一句說明（目前只有「與 Hub 共用同一份設定檔」）。
  final String? note;

  /// 有值時在欄位下方畫一列唯讀的 token（遮罩＋複製）。
  final String? readOnlyToken;

  final String savedMessage;

  /// 存完之後順手給一顆「重啟 Hub」。
  final bool offerRestart;

  final void Function(WidgetRef ref) onSaved;

  @override
  ConsumerState<_EnvEditor> createState() => _EnvEditorState();
}

class _EnvEditorState extends ConsumerState<_EnvEditor> {
  final _controllers = <String, TextEditingController>{};
  final _initial = <String, String>{};
  final _errors = <String, EnvFieldError?>{};
  final _revealed = <String>{};
  bool _saving = false;
  bool _saved = false;
  bool _restarting = false;
  bool _showAdvanced = false;

  List<_EnvFieldSpec> get _all => [...widget.fields, ...widget.advanced];

  @override
  void initState() {
    super.initState();
    for (final spec in _all) {
      final text = _display(spec, widget.values[spec.key] ?? '');
      _initial[spec.key] = text;
      _controllers[spec.key] = TextEditingController(text: text);
    }
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  /// 檔案裡的值 → 畫面上的值。目前只有「秒改成分鐘」這一種。
  String _display(_EnvFieldSpec spec, String stored) {
    final text = stored.trim();
    if (spec.kind != _EnvKind.minutes || text.isEmpty) return text;
    final seconds = double.tryParse(text);
    if (seconds == null) return text;
    final minutes = seconds / 60;
    return minutes == minutes.roundToDouble()
        ? minutes.round().toString()
        : minutes.toStringAsFixed(2);
  }

  /// 畫面上的值 → 寫回檔案的值。
  String _stored(_EnvFieldSpec spec, String shown) {
    final text = shown.trim();
    if (spec.kind != _EnvKind.minutes || text.isEmpty) return text;
    final minutes = double.tryParse(text);
    if (minutes == null) return text;
    return (minutes * 60).round().toString();
  }

  bool _changed(_EnvFieldSpec spec) =>
      _controllers[spec.key]!.text.trim() != _initial[spec.key];

  bool get _dirty => _all.any(_changed);

  /// 本來就有值的欄位不能被清空——`CHATROOM_IDLE_TIMEOUT=` 這種空值會讓
  /// Hub 在讀設定時就起不來，而畫面上只會顯示「已存檔」。
  EnvFieldError? _validate(_EnvFieldSpec spec, String value) {
    final required = (widget.values[spec.key] ?? '').trim().isNotEmpty;
    switch (spec.kind) {
      case _EnvKind.port:
        return validateEnvPort(value, required: required);
      case _EnvKind.nonNegInt:
        return validateEnvNonNegativeInt(value, required: required);
      case _EnvKind.minutes:
        return _validateMinutes(value, required: required);
      case _EnvKind.url:
        return validateEnvUrl(value, required: required);
      case _EnvKind.text:
      case _EnvKind.choice:
        return required ? validateEnvRequiredText(value) : null;
    }
  }

  /// 分鐘可以填小數（檔案裡的秒數不見得剛好整分）。
  EnvFieldError? _validateMinutes(String value, {required bool required}) {
    final text = value.trim();
    if (text.isEmpty) return required ? EnvFieldError.required : null;
    final n = double.tryParse(text);
    if (n == null) return EnvFieldError.notInteger;
    if (n < 0) return EnvFieldError.negative;
    return null;
  }

  String _message(EnvFieldError error, AppLocalizations l10n) =>
      switch (error) {
        EnvFieldError.required => l10n.hostEnvErrorRequired,
        EnvFieldError.notInteger => l10n.hostEnvErrorInteger,
        EnvFieldError.portRange => l10n.hostEnvErrorPortRange,
        EnvFieldError.negative => l10n.hostEnvErrorNegative,
        EnvFieldError.badUrl => l10n.hostEnvErrorUrl,
      };

  Future<void> _save() async {
    // await 之後不能再碰 context，先把字拿在手上
    final l10n = AppLocalizations.of(context);

    // 只驗改過的欄位：沒碰過的值本來就不會寫回去，攔住它只會讓人被一個
    // 自己沒動過的欄位擋在門外
    final errors = <String, EnvFieldError?>{};
    for (final spec in _all.where(_changed)) {
      errors[spec.key] = _validate(spec, _controllers[spec.key]!.text);
    }
    if (errors.values.any((e) => e != null)) {
      setState(() {
        _errors
          ..clear()
          ..addAll(errors);
        _saved = false;
      });
      return;
    }

    final updates = <String, String>{};
    for (final spec in _all.where(_changed)) {
      updates[spec.key] = _stored(spec, _controllers[spec.key]!.text);
    }
    if (updates.isEmpty) return;

    setState(() => _saving = true);
    try {
      await writeEnvUpdates(File(widget.path), updates);
    } on Object catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      // 🔴 訊息裡只有例外本身，不帶欄位值——token 走的是同一條路
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(l10n.hostEnvWriteFailed('$e'))));
      return;
    }
    widget.onSaved(ref);
    if (!mounted) return;
    setState(() {
      _saving = false;
      _saved = true;
      // 存完之後這幾個值就是新的基準，否則儲存鈕會一直亮著
      for (final spec in _all) {
        _initial[spec.key] = _controllers[spec.key]!.text.trim();
      }
    });
  }

  /// 存完就在旁邊重啟——不必自己翻回上面那一區。停再起，與那一區的兩顆
  /// 按鈕做的是同一件事。
  Future<void> _restartHub() async {
    final actions = ref.read(hostActionsProvider);
    if (actions == null) return;
    setState(() => _restarting = true);
    try {
      await actions.stopHub();
      await actions.startHub();
    } on Object {
      // 起停的結果看上面那一區的燈，這裡不另外編一句話
    }
    ref.invalidate(hostHealthProvider);
    if (mounted) setState(() => _restarting = false);
  }

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    final l10n = AppLocalizations.of(context);
    final token = widget.readOnlyToken ?? '';

    return _Panel(
      title: widget.title,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (widget.note != null) ...[
            Text(widget.note!,
                style: UepText.serif(size: 13, color: s.inkMute, height: 1.6)),
            const SizedBox(height: 14),
          ],
          for (final spec in widget.fields) _field(spec, l10n),
          if (token.isNotEmpty) ...[
            _TokenRow(label: l10n.hostEnvLabelHubToken, value: token),
            Padding(
              padding: const EdgeInsets.only(left: 140, top: 2, bottom: 8),
              child: Text(l10n.hostEnvTokenReadOnly,
                  style: UepText.code(size: 10.5, color: s.inkMute)),
            ),
          ],
          if (widget.advanced.isNotEmpty) _advanced(s, l10n),
          const SizedBox(height: 6),
          SelectableText(widget.path,
              style: UepText.code(size: 11.5, color: s.inkMute)),
          const SizedBox(height: 14),
          Row(children: [
            UepButton(
              label: l10n.commonSave,
              small: true,
              onPressed: (_saving || !_dirty) ? null : _save,
            ),
            if (_saved && !_dirty) ...[
              const SizedBox(width: 14),
              Flexible(
                child: Text(widget.savedMessage,
                    style: UepText.serif(
                        size: 12.5, color: UepColors.success, height: 1.4)),
              ),
              if (widget.offerRestart) ...[
                const SizedBox(width: 12),
                UepButton(
                  label: _restarting
                      ? l10n.hostEnvRestarting
                      : l10n.hostEnvRestartHub,
                  small: true,
                  variant: UepButtonVariant.outline,
                  onPressed: _restarting ? null : _restartHub,
                ),
              ],
            ],
          ]),
        ],
      ),
    );
  }

  /// 不常碰的那幾個收在這裡，排法與執行器分頁的「進階」同一套。
  Widget _advanced(UepSurface s, AppLocalizations l10n) {
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding: EdgeInsets.zero,
        initiallyExpanded: _showAdvanced,
        onExpansionChanged: (v) => _showAdvanced = v,
        title: Text(l10n.hostRunnerAdvanced,
            style: UepText.fieldLabel(color: s.inkMute)),
        children: [
          for (final spec in widget.advanced) _field(spec, l10n),
        ],
      ),
    );
  }

  /// 一列：左邊標籤，右邊輸入；變數名與錯誤話都在輸入下面。
  Widget _field(_EnvFieldSpec spec, AppLocalizations l10n) {
    final s = context.uep;
    final error = _errors[spec.key];

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            SizedBox(
              width: 140,
              child: Text(spec.label(l10n),
                  style: UepText.fieldLabel(color: s.inkMute)),
            ),
            Expanded(child: _input(spec, l10n)),
          ]),
          Padding(
            padding: const EdgeInsets.only(left: 140, top: 2),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 變數名留著：改完要回檔案裡對照的人，靠的是這一行
                Text(spec.key,
                    style: UepText.code(size: 10.5, color: s.inkMute)),
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Text(_message(error, l10n),
                        style:
                            UepText.serif(size: 12.5, color: UepColors.error)),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _input(_EnvFieldSpec spec, AppLocalizations l10n) {
    final s = context.uep;

    if (spec.kind == _EnvKind.choice) {
      final current = _controllers[spec.key]!.text.trim();
      final value = spec.options.contains(current) ? current : '';
      return DropdownButton<String>(
        value: value,
        isExpanded: true,
        underline: const SizedBox.shrink(),
        style: UepText.code(size: 12.5, color: s.ink),
        dropdownColor: s.bgSoft,
        items: [
          for (final option in spec.options)
            DropdownMenuItem(
              value: option,
              child: Text(
                option.isEmpty ? l10n.hostEnvLogLevelDefault : option,
                style: option.isEmpty
                    ? UepText.serif(size: 13, color: s.inkMute)
                    : UepText.code(size: 12.5, color: s.ink),
              ),
            ),
        ],
        onChanged: _saving
            ? null
            : (v) => setState(() {
                  _controllers[spec.key]!.text = v ?? '';
                  _errors[spec.key] = null;
                  _saved = false;
                }),
      );
    }

    final hidden = spec.secret && !_revealed.contains(spec.key);
    return TextField(
      key: Key('env-field-${spec.key}'),
      controller: _controllers[spec.key],
      enabled: !_saving,
      obscureText: hidden,
      keyboardType: switch (spec.kind) {
        _EnvKind.port ||
        _EnvKind.nonNegInt ||
        _EnvKind.minutes =>
          TextInputType.number,
        _ => null,
      },
      style: UepText.code(size: 12.5, color: s.ink),
      decoration: InputDecoration(
        isDense: true,
        hintText: l10n.hostEnvDefaultHint,
        hintStyle: UepText.serif(size: 12.5, color: s.inkMute),
        suffixIcon: spec.secret
            ? IconButton(
                tooltip: hidden ? l10n.commonShow : l10n.commonHide,
                icon: Icon(
                    hidden
                        ? Icons.visibility_off_outlined
                        : Icons.visibility_outlined,
                    size: 16,
                    color: s.inkMute),
                onPressed: () => setState(() => hidden
                    ? _revealed.add(spec.key)
                    : _revealed.remove(spec.key)),
              )
            : null,
      ),
      onChanged: (v) => setState(() {
        _errors[spec.key] = _validate(spec, v);
        _saved = false;
      }),
    );
  }
}

/// 改不得的 token：遮起來、可以複製。
///
/// 換 token 要重發給所有成員，那是 `scripts/rotate-token.py` 的事——在這裡
/// 讓人隨手改一個字，結果是所有 agent 同時連不上，而畫面上只寫了「已存檔」。
class _TokenRow extends StatefulWidget {
  const _TokenRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  State<_TokenRow> createState() => _TokenRowState();
}

class _TokenRowState extends State<_TokenRow> {
  bool _revealed = false;
  bool _copied = false;

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    final l10n = AppLocalizations.of(context);
    return Row(children: [
      SizedBox(
        width: 140,
        child: Text(widget.label, style: UepText.fieldLabel(color: s.inkMute)),
      ),
      Expanded(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
          decoration: BoxDecoration(
            color: s.bgSunken,
            border: Border.all(color: s.line),
            borderRadius: BorderRadius.circular(5),
          ),
          child: Text(
            _revealed ? widget.value : '•' * 24,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: UepText.code(size: 12.5, color: s.ink),
          ),
        ),
      ),
      IconButton(
        tooltip: _revealed ? l10n.commonHide : l10n.commonShow,
        icon: Icon(
            _revealed
                ? Icons.visibility_off_outlined
                : Icons.visibility_outlined,
            size: 16,
            color: s.inkMute),
        onPressed: () => setState(() => _revealed = !_revealed),
      ),
      IconButton(
        tooltip: _copied ? l10n.commonCopied : l10n.commonCopy,
        icon: Icon(_copied ? Icons.check : Icons.copy,
            size: 16, color: _copied ? UepColors.success : s.inkMute),
        onPressed: () async {
          await Clipboard.setData(ClipboardData(text: widget.value));
          if (!mounted) return;
          setState(() => _copied = true);
          // 回到原狀，否則下一次複製看不出來有沒有成功
          await Future<void>.delayed(const Duration(seconds: 2));
          if (mounted) setState(() => _copied = false);
        },
      ),
    ]);
  }
}

/// 與本頁其他區塊同一個外框：小標＋內容，分段交給頁面上的分隔線。
class _Panel extends StatelessWidget {
  const _Panel({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: UepText.fieldLabel(color: context.uep.inkMute)),
        const SizedBox(height: 12),
        SizedBox(width: double.infinity, child: child),
      ],
    );
  }
}
