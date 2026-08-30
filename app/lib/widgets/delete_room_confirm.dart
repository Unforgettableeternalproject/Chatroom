import 'package:flutter/material.dart';

import '../core/theme/uep_theme.dart';
import '../core/theme/uep_tokens.dart';
import 'uep_button.dart';

/// 刪除房間的確認。要把房名打一次才刪得掉。
///
/// 用打字而不是「你確定嗎？」：確認框點久了就變成反射動作，而這個動作沒有
/// 反悔的機會。打字強迫人看一眼自己要刪的是哪一間。
///
/// 放在共用的地方是因為入口有兩個——房間列表的卡片選單（封存房的操作場景
/// 就在那裡）與聊天畫面的選單。兩份各自維護的話遲早會漂移，而漂移的方向
/// 通常是「其中一份忘了要求打字」。
class DeleteRoomConfirm extends StatefulWidget {
  const DeleteRoomConfirm({super.key, required this.name});

  final String name;

  @override
  State<DeleteRoomConfirm> createState() => _DeleteRoomConfirmState();
}

class _DeleteRoomConfirmState extends State<DeleteRoomConfirm> {
  final _typed = TextEditingController();

  @override
  void dispose() {
    _typed.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    final matches = _typed.text.trim() == widget.name;
    return AlertDialog(
      title: Text('永久刪除房間',
          style: UepText.display(size: 22, color: s.inkTitle)),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '「${widget.name}」連同房裡的訊息與附件會被永久刪除，不可復原。'
                '房內的 agent 下次呼叫時會發現房間已經不存在。\n\n'
                '確認的話，把房名打一次：',
                style: UepText.serif(size: 12.5, color: s.ink, height: 1.6),
              ),
            ),
            const SizedBox(height: 12),
            Container(
              decoration: BoxDecoration(
                color: s.bgSunken,
                border: Border.all(color: s.lineStrong),
                borderRadius: BorderRadius.circular(8),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: TextField(
                controller: _typed,
                autofocus: true,
                onChanged: (_) => setState(() {}),
                style: UepText.code(size: 12.5, color: s.ink),
                decoration: InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  hintText: widget.name,
                  hintStyle: UepText.code(size: 12.5, color: s.inkMute),
                  contentPadding: const EdgeInsets.symmetric(vertical: 10),
                ),
              ),
            ),
          ]),
        ),
      ),
      actions: [
        UepButton(
          label: '取消',
          variant: UepButtonVariant.outline,
          small: true,
          onPressed: () => Navigator.of(context).pop(false),
        ),
        UepButton(
          label: '永久刪除',
          small: true,
          onPressed: matches ? () => Navigator.of(context).pop(true) : null,
        ),
      ],
    );
  }
}
