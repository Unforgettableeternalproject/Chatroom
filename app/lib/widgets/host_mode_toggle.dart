import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme/uep_theme.dart';
import '../core/theme/uep_tokens.dart';
import '../state/app_providers.dart';

/// 主持人模式開關。**ROOMS 與 BOARDS 兩個分頁共用同一顆。**
///
/// 開著時清單含**所有人的**東西（含自己沒份的私人房／私人板），所以它必須
/// 在畫面上看得出來——一份清單兩種含意而外觀一樣，是最容易讓人把別人的
/// 私人東西當成自己的那種形狀。開著時整條變成金色並明說現在看到的是什麼。
///
/// ⚠️ **`onLabel` 由呼叫端給。** `hostViewProvider` 是全域的、`X-Host-View`
/// 由 api_client 依它自動帶——所以在 ROOMS 打開，切到 BOARDS 也生效。
/// 兩邊共用一句「看得到全部聊天室」的話，那句話在 BOARDS 分頁下是錯的
/// （看得到的是板），而**錯的說明比沒有說明更難察覺**（2026-09-04）。
class HostModeToggle extends ConsumerWidget {
  const HostModeToggle({
    super.key,
    required this.on,
    required this.onLabel,
    this.warn = false,
  });

  final bool on;

  /// 開著的時候要說的那句話——講**這個分頁**現在多看到了什麼。
  final String onLabel;

  /// 開關是開的、但 server 沒有照做。
  ///
  /// 🔴 這是唯一會提示這件事的地方：Hub 的 `host_view` 要兩個條件（明示
  /// 標頭＋主 token），任一沒滿足就靜靜降級成一般視角——而少掉的東西
  /// 本來就看不到，**畫面完全一樣**。不講的話，「開關壞了」與「別人沒有
  /// 私人板」在畫面上是同一件事。
  final bool warn;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.uep;
    final accent = warn ? UepColors.error : UepColors.gold;
    return InkWell(
      onTap: () => ref.read(hostViewProvider.notifier).toggle(),
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: on ? accent.withValues(alpha: .09) : null,
          border: Border.all(
            color: on ? accent.withValues(alpha: .5) : s.line,
          ),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(children: [
          Icon(
            warn
                ? Icons.error_outline
                : (on ? Icons.visibility : Icons.visibility_off_outlined),
            size: 14,
            color: on ? accent : s.inkMute,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              warn
                  ? '主持人模式沒有生效——伺服器沒有照做'
                  : (on ? onLabel : '主持人模式'),
              style: UepText.sans(
                size: 11.5,
                color: on ? accent : s.inkMute,
                weight: on ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ),
        ]),
      ),
    );
  }
}
