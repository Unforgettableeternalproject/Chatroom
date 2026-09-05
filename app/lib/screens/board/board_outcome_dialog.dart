import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/errors/api_exception.dart';
import '../../core/theme/uep_theme.dart';
import '../../core/theme/uep_tokens.dart';
import '../../state/board_providers.dart';
import '../../state/app_providers.dart';
import '../../widgets/uep_button.dart';

/// 宣告一塊板的**結局**：完成／廢止，或把它重新打開（N-2 / N-3）。
///
/// ## 為什麼不是「封存」
///
/// `archived` 說的是「還能不能編輯」——那是收納，可逆，與這件事做完了沒有
/// 無關。`outcome` 說的是**這件事後來怎麼了**。兩個軸都存在，因為「做完了
/// 但先留著」與「還沒做完就收起來」都是真實的狀態。
///
/// ## 為什麼只有人類按得到
///
/// Hub 限人類 owner（403 `human_only`），理由與 Objective 的 `verified`
/// 那道閘相同：判斷「這件事真的做完了嗎」的實際意義是跑測試、看畫面、確認
/// 沒踩到坑，那件事只有人做得到。App 的操作者本來就是人，所以這裡只看
/// owner——**那個 403 是兜底，不是 UI 的判準**。
Future<void> showBoardOutcomeDialog(
  BuildContext context, {
  required String boardId,
  required String current,
}) =>
    showDialog<void>(
      context: context,
      builder: (_) => _OutcomeDialog(boardId: boardId, current: current),
    );

class _OutcomeDialog extends ConsumerStatefulWidget {
  const _OutcomeDialog({required this.boardId, required this.current});

  final String boardId;
  final String current;

  @override
  ConsumerState<_OutcomeDialog> createState() => _OutcomeDialogState();
}

class _OutcomeDialogState extends ConsumerState<_OutcomeDialog> {
  bool _busy = false;
  String? _error;

  Future<void> _set(String outcome) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(boardsApiProvider).setOutcome(
            widget.boardId,
            sessionKey: ref.read(appConfigProvider).deviceKey,
            outcome: outcome,
          );
      ref.invalidate(boardByIdProvider(widget.boardId));
      // 清單那三頁的內容都會變（收尾的板會從「進行中」移到「已收尾」），
      // 三頁各自是一個 family instance，**一頁一頁 invalidate**
      for (final v in ['active', 'archived', 'settled']) {
        ref.invalidate(boardLibraryProvider(v));
      }
      if (mounted) Navigator.of(context).pop();
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.code == 'human_only'
          // 這句話幾乎不會出現在 App 上（操作者是人），但出現的時候要說得出
          // 為什麼，而不是一句「沒有權限」
          ? '宣告結局限人類 owner——「真的做完了嗎」要跑測試、看畫面才判斷得出來。'
          : e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    final settled = widget.current.isNotEmpty;
    return AlertDialog(
      backgroundColor: s.bgCard,
      title: Text(settled ? '這塊板的結局' : '宣告結局',
          style: UepText.display(size: 18, color: s.inkTitle)),
      content: SizedBox(
        width: 380,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(
            settled
                ? '它現在是「${widget.current == 'completed' ? '完成' : '廢止'}」，'
                    '不會出現在進行中的清單裡。改主意的話可以重新打開。'
                : '收尾之後這塊板不再佔著「進行中」那一頁，但**不會消失**——'
                    '切到「已收尾」找得回來，也隨時可以重新打開。\n\n'
                    '這與封存是兩件事：封存只是不能再改，這裡說的是結局。',
            style: UepText.serif(size: 12, color: s.inkMute, height: 1.55),
          ),
          if (_error != null) ...[
            const SizedBox(height: 10),
            Text(_error!,
                style: UepText.sans(
                    size: 12, color: UepColors.error, height: 1.45)),
          ],
        ]),
      ),
      actions: [
        UepButton(
          label: '取消',
          variant: UepButtonVariant.outline,
          small: true,
          onPressed: () => Navigator.of(context).pop(),
        ),
        if (settled)
          UepButton(
            label: '重新打開',
            small: true,
            onPressed: _busy ? null : () => _set(''),
          )
        else ...[
          // 廢止畫成 danger：它與完成同樣是收尾，但語意是「不做了」，
          // 兩顆長一樣的話按錯不會有任何提示
          UepButton(
            label: '廢止',
            variant: UepButtonVariant.danger,
            small: true,
            onPressed: _busy ? null : () => _set('abandoned'),
          ),
          UepButton(
            label: '完成',
            small: true,
            onPressed: _busy ? null : () => _set('completed'),
          ),
        ],
      ],
    );
  }
}
