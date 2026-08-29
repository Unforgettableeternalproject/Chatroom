import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/config/invite_code.dart';
import '../core/errors/api_exception.dart';
import '../core/theme/uep_theme.dart';
import '../core/theme/uep_tokens.dart';
import '../core/util/relative_time.dart';
import '../state/app_providers.dart';
import '../state/assignments_providers.dart';
import 'uep_button.dart';

/// 設定頁的「邀請成員」區塊：發一份邀請給還沒連上 Hub 的人，以及收回已發出的。
///
/// 只有 Hub 主持人（`.env` 那把主 token）能用；其他人拿到 403，這裡把它畫成
/// 說明而不是錯誤——「這台不是你主持的」不是故障。
class InviteManager extends ConsumerStatefulWidget {
  const InviteManager({super.key});

  @override
  ConsumerState<InviteManager> createState() => _InviteManagerState();
}

class _InviteManagerState extends ConsumerState<InviteManager> {
  final _label = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _label.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    setState(() => _busy = true);
    try {
      final created =
          await ref.read(tokensApiProvider).create(label: _label.text.trim());
      _label.clear();
      ref.invalidate(accessTokensProvider);
      if (mounted) await _showCode(created.token, created.label);
    } on ApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _showCode(String token, String label) async {
    final config = ref.read(appConfigProvider);
    final code = InviteCode(
      serverUrl: config.serverUrl,
      token: token,
      label: label,
    ).encode();
    await showDialog<void>(
      context: context,
      builder: (context) {
        final s = context.uep;
        return AlertDialog(
          backgroundColor: s.bgCard,
          title: Text('邀請碼${label.isEmpty ? '' : '：$label'}',
              style: UepText.display(size: 22, color: s.inkTitle)),
          content: SizedBox(
            width: 440,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: s.bgSunken,
                  border: Border.all(color: s.lineStrong),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: SelectableText(code,
                    style:
                        UepText.code(size: 11, color: s.ink, height: 1.6)),
              ),
              const SizedBox(height: 12),
              Text(
                '對方在「設定 → 貼上邀請碼」貼進去就能連上。\n'
                '這串字等同密碼——任何拿到的人都能進這台 Hub，'
                '用私訊給，不要貼在公開頻道。',
                style:
                    UepText.serif(size: 12.5, color: s.inkMute, height: 1.7),
              ),
              const SizedBox(height: 8),
              Text(
                // 主持人常忘記這件事，事後會以為是邀請壞了
                '註：隧道網址每次重啟都會變。網址換過之後這份邀請碼要重發一次，'
                '但 token 本身仍然有效。',
                style:
                    UepText.serif(size: 12, color: s.inkMute, height: 1.7),
              ),
            ]),
          ),
          actions: [
            UepButton(
              label: '複製',
              small: true,
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: code));
                if (context.mounted) Navigator.of(context).pop();
              },
            ),
            UepButton(
              label: '關閉',
              variant: UepButtonVariant.outline,
              small: true,
              onPressed: () => Navigator.of(context).pop(),
            ),
          ],
        );
      },
    );
  }

  Future<void> _revoke(String token, String label) async {
    final s = context.uep;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: s.bgCard,
        title: Text('撤銷這份邀請？',
            style: UepText.display(size: 22, color: s.inkTitle)),
        content: Text(
          '${label.isEmpty ? '這張 token' : label}將立刻失去存取權，'
          '正在連線中的也會在下一次請求時被擋下。此操作無法復原。',
          style: UepText.serif(size: 13.5, color: s.inkSoft, height: 1.7),
        ),
        actions: [
          UepButton(
            label: '取消',
            variant: UepButtonVariant.outline,
            small: true,
            onPressed: () => Navigator.of(context).pop(false),
          ),
          UepButton(
            label: '撤銷',
            variant: UepButtonVariant.danger,
            small: true,
            onPressed: () => Navigator.of(context).pop(true),
          ),
        ],
      ),
    );
    if (!(ok ?? false)) return;
    try {
      await ref.read(tokensApiProvider).revoke(token);
    } on ApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
      }
    } finally {
      ref.invalidate(accessTokensProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    final tokensAsync = ref.watch(accessTokensProvider);

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('邀請成員', style: UepText.sans(size: 13.5, color: s.inkTitle)),
      const SizedBox(height: 3),
      Text(
        '發一份邀請給還沒連上這台 Hub 的人。每份邀請可以單獨撤銷，'
        '不必換掉所有人的 token。',
        style: UepText.serif(size: 12, color: s.inkMute, height: 1.7),
      ),
      const SizedBox(height: 12),
      Row(children: [
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              color: s.bgSunken,
              border: Border.all(color: s.lineStrong),
              borderRadius: BorderRadius.circular(8),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: TextField(
              controller: _label,
              maxLength: 64,
              style: UepText.sans(size: 12.5, color: s.ink),
              decoration: InputDecoration(
                isDense: true,
                border: InputBorder.none,
                counterText: '',
                hintText: '這份發給誰？（選填，只有你看得到）',
                hintStyle: UepText.serif(size: 12.5, color: s.inkMute),
                contentPadding: const EdgeInsets.symmetric(vertical: 11),
              ),
            ),
          ),
        ),
        const SizedBox(width: 10),
        UepButton(
          label: '產生邀請碼',
          small: true,
          onPressed: _busy ? null : _create,
        ),
      ]),
      const SizedBox(height: 14),
      tokensAsync.when(
        loading: () => const SizedBox(
            height: 20,
            child: Center(
                child: SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: UepColors.gold)))),
        error: (e, _) => Text(
          // 不是故障：這台 Hub 由別人主持，發放權留在他那裡
          e is RootTokenRequiredException
              ? '只有 Hub 主持人能發放與撤銷邀請。'
              : e is ApiException
                  ? e.message
                  : '無法讀取已發出的邀請',
          style: UepText.serif(size: 12, color: s.inkMute, height: 1.7),
        ),
        data: (tokens) => tokens.isEmpty
            ? Text('還沒發出任何邀請',
                style: UepText.serif(size: 12, color: s.inkMute))
            : Column(children: [
                for (final t in tokens)
                  Container(
                    padding: const EdgeInsets.symmetric(vertical: 9),
                    decoration: BoxDecoration(
                        border:
                            Border(top: BorderSide(color: s.line))),
                    child: Row(children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                                t.label.isEmpty ? '（未命名）' : t.label,
                                style: UepText.sans(
                                    size: 12.5,
                                    weight: FontWeight.w600,
                                    color: s.inkTitle)),
                            const SizedBox(height: 2),
                            Text(
                              t.lastUsedAt == null
                                  // 從沒用過通常表示邀請沒送到，而不是對方不想用
                                  ? '尚未使用 · 發於 ${relativeTime(t.createdAt)}'
                                  : '最後使用 ${relativeTime(t.lastUsedAt!)}',
                              style: UepText.mono(size: 9, color: s.inkMute),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        tooltip: '重新顯示邀請碼',
                        visualDensity: VisualDensity.compact,
                        onPressed: () => _showCode(t.token, t.label),
                        icon: Icon(Icons.qr_code_2,
                            size: 15, color: s.inkMute),
                      ),
                      IconButton(
                        tooltip: '撤銷',
                        visualDensity: VisualDensity.compact,
                        onPressed: () => _revoke(t.token, t.label),
                        icon: Icon(Icons.block,
                            size: 15, color: UepColors.errorText),
                      ),
                    ]),
                  ),
              ]),
      ),
    ]);
  }
}
