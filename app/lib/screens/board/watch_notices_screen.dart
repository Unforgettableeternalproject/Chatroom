import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/errors/api_exception.dart';
import '../../core/theme/uep_theme.dart';
import '../../core/theme/uep_tokens.dart';
import '../../models/scratchpad.dart';
import '../../state/app_providers.dart';
import '../../state/scratchpad_providers.dart';
import '../../widgets/empty_error_states.dart';
import '../../widgets/uep_button.dart';

/// 追蹤收件匣。**跨板**——「我在等的東西完成了嗎」不分板。
///
/// 裁決 #392 ②A 是「追蹤者離線時通知留著，回來就知道」。**知道的管道就是
/// 這裡**：少了它，通知留著了，但沒有任何地方會告訴他有東西留著，
/// 而 ②A 在實際使用上就等於「不通知」。
class WatchNoticesScreen extends ConsumerWidget {
  const WatchNoticesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.uep;
    final async = ref.watch(watchNoticesProvider);
    return Scaffold(
      backgroundColor: s.bg,
      appBar: AppBar(
        backgroundColor: s.bg,
        title: Text('我在等的東西',
            style: UepText.display(size: 20, color: s.inkTitle)),
        actions: [
          async.maybeWhen(
            data: (d) => d.unread == 0
                ? const SizedBox.shrink()
                : Padding(
                    padding: const EdgeInsets.only(right: 12),
                    child: Center(
                      child: UepButton(
                        label: '全部標為已讀',
                        variant: UepButtonVariant.outline,
                        small: true,
                        onPressed: () => _markAll(context, ref),
                      ),
                    ),
                  ),
            orElse: () => const SizedBox.shrink(),
          ),
        ],
      ),
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => ErrorState(
          error: e,
          onRetry: () => ref.invalidate(watchNoticesProvider),
        ),
        data: (d) => d.notices.isEmpty
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Text(
                    '沒有在等的東西。\n'
                    '在卡片上按那顆鈴鐺，它完成或又被打開時這裡會出現一筆。',
                    textAlign: TextAlign.center,
                    style: UepText.serif(
                        size: 13, color: s.inkMute, height: 1.6),
                  ),
                ),
              )
            : ListView.builder(
                padding: const EdgeInsets.symmetric(vertical: 8),
                itemCount: d.notices.length,
                itemBuilder: (_, i) => _NoticeRow(
                  notice: d.notices[i],
                  onOpen: () => _open(context, ref, d.notices[i]),
                ),
              ),
      ),
    );
  }

  Future<void> _markAll(BuildContext context, WidgetRef ref) async {
    try {
      final n = await ref.read(watchApiProvider).markRead(
            sessionKey: ref.read(appConfigProvider).deviceKey,
            all: true,
          );
      ref.invalidate(watchNoticesProvider);
      if (!context.mounted) return;
      // 標了幾筆要說出來。**0 也說**——「本來就沒有未讀」與「這個請求
      // 根本沒送到」在畫面上長得一模一樣，而後者今天出現過兩次
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(n == 0 ? '沒有可以標記的未讀' : '$n 筆標為已讀'),
      ));
    } on ApiException catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  /// 點一筆＝去看那塊板，並把這一筆標掉。
  ///
  /// ⚠️ 標記與導覽**要一起做**。只導覽不標的話那筆會一直留著，而使用者
  /// 明明已經看過了；只標不導覽的話他得自己去找那塊板在哪。
  Future<void> _open(
      BuildContext context, WidgetRef ref, WatchNotice n) async {
    try {
      await ref.read(watchApiProvider).markRead(
            sessionKey: ref.read(appConfigProvider).deviceKey,
            noticeIds: [n.id],
          );
    } on ApiException {
      // 標不掉不該擋住導覽——他要看的是那塊板，不是這筆通知
    }
    ref.invalidate(watchNoticesProvider);
    if (!context.mounted || n.boardId.isEmpty) return;
    context.go('/boards/${n.boardId}');
  }
}

class _NoticeRow extends StatelessWidget {
  const _NoticeRow({required this.notice, required this.onOpen});

  final WatchNotice notice;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    return InkWell(
      onTap: onOpen,
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 11, 16, 11),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(color: s.hairline),
            left: BorderSide(
              // 未讀的左邊一條金線。讀過的留在清單上但不再喊——
              // 直接消失的話，人會懷疑自己剛才是不是看錯了
              color: notice.unread ? UepColors.gold : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(
            watchNoticeLabel(notice.eventType, notice.itemTitle),
            style: UepText.sans(
              size: 13,
              color: notice.unread ? s.inkTitle : s.inkMute,
              height: 1.45,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            [
              if (notice.boardName.isNotEmpty) notice.boardName,
              if (notice.actorName.isNotEmpty) notice.actorName,
            ].join(' · '),
            style: UepText.mono(size: 9, letterSpacing: 1.0, color: s.inkMute),
          ),
        ]),
      ),
    );
  }
}
