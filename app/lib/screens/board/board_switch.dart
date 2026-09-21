import 'package:flutter/material.dart';

import '../../core/theme/uep_theme.dart';
import '../../core/theme/uep_tokens.dart';
import '../../l10n/l10n.dart';
import '../../widgets/uep_button.dart';

/// 更換房間的任務板：**detach → attach 兩步，不包成一支端點**
/// （艾斯維爾 09/07 裁定第 4 點，決策照 UI 提案定形）。
///
/// 包成一支端點做得到，但那會把中間態藏起來——而它本來就會發生：
/// `attach` 那端有 `room_already_has_board` 擋著，順序不能反，所以「舊的
/// 已經解除、新的還沒掛上」是這條路上的必經之地，不是異常。
///
/// **那個中間態是使用者看得懂的狀態，不是壞掉**：這間房現在沒有板，
/// 而畫面上本來就有「掛接任務板」那條路可以走下去。把它說清楚，比讓它
/// 消失在一句「更換失敗」裡有用。

/// 兩步流程停在哪裡，就說哪一句。
///
/// ⚠️ 四種結果**必須分得出來**，因為下一步完全不同：
/// 原本的板還在（什麼都不必做）／房間現在沒有板（要再掛一塊）／換好了。
/// 全部講成「更換失敗」的話，人不知道自己的房間現在是什麼狀態——
/// 而這條流程中途的狀態剛好就是「沒有板」。
/// ⚠️ 這裡用 [L10n.current] 而不是收一個 `AppLocalizations` 參數：呼叫端
/// 散在聊天室畫面與測試裡，拿不到 context 的那幾處沒有東西可以傳。
String boardSwitchStatusMessage({
  required bool detached,
  required bool attached,
  String? error,
}) {
  final l10n = L10n.current;
  if (!detached) {
    // 第一步就沒過：什麼都沒變，原本那塊還掛著
    return error == null
        ? l10n.boardSwitchNotSwitched
        : l10n.boardSwitchNotSwitchedError(error);
  }
  if (attached) return l10n.boardSwitchDone;
  // 解除成功、新的沒接上——**這裡最要緊的是講出房間現在的狀態**
  return error == null
      ? l10n.boardSwitchDetachedOnly
      : l10n.boardSwitchDetachedOnlyError(error);
}

/// 換板前的確認。
///
/// 要講清楚**板不會被刪**——「更換」聽起來像丟掉舊的，而 detach 只解除
/// 掛接關係，板連同上面的卡都留在 Board Library 裡。不講的話，沒有人敢按。
Future<bool> confirmBoardSwitch(BuildContext context,
    {required String boardName}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) {
      final s = ctx.uep;
      final l10n = AppLocalizations.of(ctx);
      return AlertDialog(
        backgroundColor: s.bgCard,
        title: Text(l10n.boardSwitchConfirmTitle,
            style: UepText.sectionTitle(color: s.inkTitle)),
        content: SizedBox(
          width: 420,
          child: Text(
            boardName.isEmpty
                ? l10n.boardSwitchConfirmBodyUnnamed
                : l10n.boardSwitchConfirmBody(boardName),
            style: UepText.serif(size: 13.5, color: s.inkSoft, height: 1.8),
          ),
        ),
        actions: [
          UepButton(
            label: l10n.commonCancel,
            variant: UepButtonVariant.outline,
            small: true,
            onPressed: () => Navigator.of(ctx).pop(false),
          ),
          UepButton(
            label: l10n.boardSwitchConfirmAction,
            small: true,
            onPressed: () => Navigator.of(ctx).pop(true),
          ),
        ],
      );
    },
  );
  return ok ?? false;
}
