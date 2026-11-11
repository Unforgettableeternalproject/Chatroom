// 慶祝模式的樣式預覽，獨立入口，不屬於正式 App。
//
// 放在 app/tool/ 而不是 lib/：正式打包只從 lib/main.dart 往下編，tool/ 不會
// 被帶進去。啟動（在 app/ 目錄下）：
//   flutter run -d windows -t tool/celebration_demo.dart
//
// 三種事件（成員加入／任務完成／派工成功）樣式相同，所以只有一顆按鈕；
// 它走的是正式的 CelebrationController（含節流），連點可以看到合併效果。
// 下方那則假的 system 訊息用正式的 SystemMessageTile 與 CelebrationHighlight，
// 標示是文字金色呼吸一次；每次按「噴彩花」換一個新 id，所以每次都會重播。
import 'package:chatroom_app/celebration/celebration_controller.dart';
import 'package:chatroom_app/celebration/celebration_highlight.dart';
import 'package:chatroom_app/celebration/confetti_overlay.dart';
import 'package:chatroom_app/core/theme/uep_theme.dart';
import 'package:chatroom_app/core/theme/uep_tokens.dart';
import 'package:chatroom_app/models/message.dart';
import 'package:chatroom_app/widgets/system_message_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ProviderScope(child: _DemoApp()));
}

class _DemoApp extends StatelessWidget {
  const _DemoApp();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '慶祝模式預覽',
      debugShowCheckedModeBanner: false,
      theme: buildUepTheme(Brightness.dark),
      themeMode: ThemeMode.dark,
      builder: (context, child) =>
          CelebrationOverlay(child: child ?? const SizedBox.shrink()),
      home: const _DemoPage(),
    );
  }
}

class _DemoPage extends ConsumerStatefulWidget {
  const _DemoPage();

  @override
  ConsumerState<_DemoPage> createState() => _DemoPageState();
}

class _DemoPageState extends ConsumerState<_DemoPage> {
  int _n = 0;

  Message get _fake => Message(
    id: 'demo-$_n',
    seq: _n,
    updateSeq: 0,
    kind: 'system',
    content: 'Core 開發 (工具層) 加入了聊天室',
    createdAt: DateTime.now().toIso8601String(),
    systemEvent: 'join',
  );

  void _fire() {
    // 先換成新訊息（新 id 的 tile 會 build），再慶祝並標示
    setState(() => _n++);
    if (ref.read(celebrationControllerProvider).celebrate()) {
      ref.read(celebrationHighlightsProvider.notifier).mark(_fake.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    return Scaffold(
      backgroundColor: s.bg,
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('慶祝模式預覽', style: UepText.sans(size: 16, color: s.inkTitle)),
              const SizedBox(height: 6),
              Text(
                '成員加入、任務完成、派工成功都是這個效果',
                style: UepText.serif(size: 12, color: s.inkMute),
              ),
              const SizedBox(height: 24),
              SystemMessageTile(
                key: ValueKey(_fake.id),
                message: _fake,
              ).wrapHighlight(_fake.id),
              const SizedBox(height: 24),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: UepColors.gold,
                      foregroundColor: UepColors.goldInkOn,
                      minimumSize: const Size(0, 40),
                    ),
                    onPressed: _fire,
                    child: const Text('噴彩花'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

extension on Widget {
  Widget wrapHighlight(String id) =>
      CelebrationHighlight(key: ValueKey('hl-$id'), messageId: id, child: this);
}
