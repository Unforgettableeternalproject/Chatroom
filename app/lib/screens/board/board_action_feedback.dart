import 'package:flutter/material.dart';

import '../../core/errors/api_exception.dart';
import '../../l10n/l10n.dart';

/// Board 畫面所有「按下去會打 API」的動作共用的執行殼。
///
/// 存在的理由是一個具體的失效形狀：board 的按鈕原本一律寫成
/// `onTap: () => actions.xxx()`——**丟出一個沒有人接的 Future**。Hub 回 409
/// 時例外被拋進 framework，畫面上什麼都不會發生，使用者看到的是「這顆按鈕
/// 壞了」。而 `_create()` 一直都有正確的寫法，它的註解也寫明了理由，只是
/// 沒有被複製到其餘按鈕上。
///
/// 所以這裡把「await + catch + 回饋」收成一個地方：**新增按鈕時沒有比它更
/// 短的寫法**，抄捷徑才是比較累的那條路。
///
/// 回傳 `null` 代表這次動作失敗（已經對使用者說過了），呼叫端不必再處理。
Future<T?> runBoardAction<T>(
  BuildContext context,
  Future<T> Function() body, {
  /// 409 的專用出口。狀態轉移衝突多半**不是錯誤**——它帶著 `allowed`
  /// 告訴你從現在這個狀態還能去哪，呼叫端可以拿去校正畫面而不只是報錯。
  /// 不給的話走一般錯誤呈現。
  void Function(ConflictException e)? onConflict,
}) async {
  try {
    return await body();
  } on ConflictException catch (e) {
    // ⚠️ `objective_closed` 不走 [onConflict]：呼叫端拿它沒有第二條路可走
    // （解凍只有「打回」，而那是人要自己決定的一次動作），而 onConflict
    // 的既有呼叫端都是在處理 `container_settled` 那種「重開並重試」。
    if (onConflict != null && e.code != 'objective_closed') {
      onConflict(e);
      return null;
    }
    _say(context, boardActionMessage(context, e));
    return null;
  } on ApiException catch (e) {
    _say(context, boardActionMessage(context, e));
    return null;
  }
}

/// 一次被拒絕要對使用者說的那句話。
///
/// **原則仍是用 Hub 的原話**：它知道為什麼被拒絕，我們只知道被拒絕了。
/// 這裡列的是 App 講得比它具體的少數幾個 code——判準一律是 `code`，
/// 絕不對 message 做字串比對（見 [ApiException]）。
String boardActionMessage(BuildContext context, ApiException e) =>
    switch (e.code) {
      // 409 — 週期不是 active，它自己與底下的階段、任務都不可寫。
      // Hub 的原話講的是「這個 objective 關著」，而使用者手上要的是
      // 下一步：打回那顆按鈕就在週期抬頭右邊
      'objective_closed' => AppLocalizations.of(context)
          .boardErrorObjectiveClosed,
      _ => e.message,
    };

void _say(BuildContext context, String message) {
  if (!context.mounted) return;
  ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(message)));
}
