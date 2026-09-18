import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/uep_theme.dart';
import '../../core/theme/uep_tokens.dart';
import '../../widgets/kind_badge.dart';

/// 手冊。
///
/// 各畫面上不放介紹性文字，需要解釋的東西集中在這裡——功能底下逐句加註
/// 會把每個畫面都變成教學，而這個 App 的使用者是進階使用者。
///
/// 內容只講「怎麼用」，不講原理。要加東西之前先問：不知道這件事的人會做
/// 錯什麼？答不出來就不要寫。
///
/// 說明依「從哪裡按進來」分成三份：主畫面、設定、這台機器。一份說明只講
/// 那個畫面上做得到的事，按進來的人不必在整本手冊裡找自己那一段。
enum HelpTopic { main, settings, host }

/// 網址上的 topic → 列舉。未知值一律當主畫面那份。
HelpTopic helpTopicFromSlug(String? slug) {
  switch (slug) {
    case 'settings':
      return HelpTopic.settings;
    case 'host':
      return HelpTopic.host;
    default:
      return HelpTopic.main;
  }
}

/// 條目裡的一段文字。`code` 的那段畫成 chip（快捷鍵、語法、位址）。
@immutable
class HelpChunk {
  const HelpChunk.text(this.text) : isCode = false;
  const HelpChunk.code(this.text) : isCode = true;

  final String text;
  final bool isCode;
}

/// 一條說明。一到兩句，太長就拆成兩條。
@immutable
class HelpItem {
  const HelpItem(this.chunks);

  final List<HelpChunk> chunks;
}

@immutable
class HelpSection {
  const HelpSection({
    required this.label,
    required this.title,
    required this.icon,
    required this.items,
  });

  /// 導覽上的 mono 小標。
  final String label;
  final String title;
  final IconData icon;
  final List<HelpItem> items;
}

@immutable
class HelpDoc {
  const HelpDoc({required this.title, required this.sections});

  final String title;
  final List<HelpSection> sections;
}

const Map<HelpTopic, HelpDoc> kHelpDocs = {
  HelpTopic.main: HelpDoc(
    title: '使用說明',
    sections: [
      HelpSection(
        label: '聊天',
        title: '聊天室',
        icon: Icons.forum_outlined,
        items: [
          HelpItem([
            HelpChunk.code('@名字'),
            HelpChunk.text(' 提及成員，'),
            HelpChunk.code('#[標題]'),
            HelpChunk.text(' 指涉任務卡。'),
          ]),
          HelpItem([
            HelpChunk.code('Enter'),
            HelpChunk.text(' 送出，'),
            HelpChunk.code('Shift+Enter'),
            HelpChunk.text(' 換行，'),
            HelpChunk.code('↑↓'),
            HelpChunk.text(' 叫回歷史。'),
          ]),
          HelpItem([HelpChunk.text('檔案可以拖進輸入框，也可以直接貼上截圖。')]),
          HelpItem([HelpChunk.text('私人聊天室不會出現在別人的列表裡，必須受邀才能加入。')]),
          HelpItem([HelpChunk.text('封存後只能看不能寫；封存一段時間後 Hub 會把房間連同訊息與附件永久刪除。')]),
        ],
      ),
      HelpSection(
        label: '任務板',
        title: '任務板',
        icon: Icons.dashboard_outlined,
        items: [
          HelpItem([HelpChunk.text('板不屬於任何一間房，一塊板可以掛在好幾間聊天室上。解除掛接不會刪掉板。')]),
          HelpItem([HelpChunk.text('結構是週期 → 階段 → 任務。所有階段收尾後才能送審，未分類的卡也要先收尾。')]),
          HelpItem([HelpChunk.text('「搬到別處」會在目標階段建立一張新卡，原本那張標成「已搬走」。')]),
          HelpItem([
            HelpChunk.text('想法板（'),
            HelpChunk.code('SCRATCHPAD'),
            HelpChunk.text('）放還沒拆成卡的東西；agent 讀得到、也能留意見，但改不動你寫的內容。'),
          ]),
          HelpItem([HelpChunk.text('板的 owner 決定誰能編輯。在同一間房裡不會自動成為板的協作者。')]),
        ],
      ),
      HelpSection(
        label: '派工',
        title: '派工',
        icon: Icons.play_circle_outline,
        items: [
          HelpItem([
            HelpChunk.text('派工要有執行器在線，而且目標專案在它的 '),
            HelpChunk.code('projects'),
            HelpChunk.text(' 白名單裡，否則 Hub 會擋下建單。'),
          ]),
          HelpItem([HelpChunk.text('推送會先比對待推的 commit 與畫面上看到的是否一致，不一致就不推並回報。')]),
        ],
      ),
      HelpSection(
        label: '通知',
        title: '通知',
        icon: Icons.notifications_outlined,
        items: [
          HelpItem([HelpChunk.text('系統通知只在 App 開著時發，關閉期間的訊息不會補發，回來後靠未讀紅點找。')]),
        ],
      ),
    ],
  ),
  HelpTopic.settings: HelpDoc(
    title: '設定說明',
    sections: [
      HelpSection(
        label: '邀請',
        title: '邀請與 token',
        icon: Icons.vpn_key_outlined,
        items: [
          HelpItem([HelpChunk.text('邀請碼等同密碼，用私訊給，不要貼在公開頻道。每份邀請可以單獨撤銷，不必換掉所有人的 token。')]),
          HelpItem([HelpChunk.text('人類 token 與 Agent token 是兩把：只有人類 token 開得了主持人模式、發得了邀請。')]),
          HelpItem([
            HelpChunk.text('Agent token 填進 mcp-kit 安裝器的「'),
            HelpChunk.code('Agent token'),
            HelpChunk.text('」欄位。'),
          ]),
          HelpItem([HelpChunk.text('把成員移出聊天室會撤銷他當初用的那張邀請碼，與他共用同一張的人會一起斷線。')]),
        ],
      ),
      HelpSection(
        label: '版本',
        title: '版本',
        icon: Icons.verified_outlined,
        items: [
          HelpItem([HelpChunk.text('橫幅說「App 版本較舊」就更新 App。')]),
          HelpItem([HelpChunk.text('兩邊的 commit 在設定頁與橫幅的 tooltip 上，回報問題時附上。')]),
          HelpItem([
            HelpChunk.text('要確認 agent 用的是哪一份 bridge，讓它呼叫 '),
            HelpChunk.code('chatroom_join'),
            HelpChunk.text('，比對回傳的 '),
            HelpChunk.code('bridge.commit'),
            HelpChunk.text('。'),
          ]),
        ],
      ),
      HelpSection(
        label: '通知',
        title: '通知',
        icon: Icons.notifications_outlined,
        items: [
          HelpItem([HelpChunk.text('「轉送通知給 Codex」會把提及與 Board 變動送到本機 Codex session。')]),
        ],
      ),
    ],
  ),
  HelpTopic.host: HelpDoc(
    title: '主控台說明',
    sections: [
      HelpSection(
        label: '主機',
        title: '這台機器',
        icon: Icons.dns_outlined,
        items: [
          HelpItem([HelpChunk.text('只有裝了 host-kit 或 mcp-kit 的機器看得到這個入口。')]),
          HelpItem([HelpChunk.text('Hub：本機的伺服器進程。關掉 App 不會停 Hub。')]),
          HelpItem([HelpChunk.text('自動啟動：一般權限註冊＝登入時自啟；以系統管理員執行 App 再註冊＝開機自啟。')]),
          HelpItem([
            HelpChunk.text('綁在 '),
            HelpChunk.code('0.0.0.0'),
            HelpChunk.text(' 時，發給成員的位址要換成他們連得到的 IP。'),
          ]),
        ],
      ),
      HelpSection(
        label: '通道',
        title: '隧道、備份與 token',
        icon: Icons.cloud_outlined,
        items: [
          HelpItem([HelpChunk.text('隧道：把這台 Hub 放到公網上，擋在前面的只有 token。')]),
          HelpItem([HelpChunk.text('一次只能有一條，要換網址先關閉再開。網址每次重開都會變，換過之後邀請碼要重發。')]),
          HelpItem([
            HelpChunk.text('備份：資料庫與 '),
            HelpChunk.code('attachments/'),
            HelpChunk.text(' 一起收進 '),
            HelpChunk.code('backups\\'),
            HelpChunk.text('。還原前 Hub 必須先停止，而且會自動先備份現況。'),
          ]),
          HelpItem([HelpChunk.text('換 token：重啟 Hub 後才生效，之後每個成員都要換成新的。')]),
        ],
      ),
      HelpSection(
        label: '版本',
        title: '版本',
        icon: Icons.verified_outlined,
        items: [
          HelpItem([HelpChunk.text('橫幅說「Hub 版本較舊」就更新 Hub。')]),
        ],
      ),
    ],
  ),
};

class HelpScreen extends StatefulWidget {
  const HelpScreen({super.key, this.topic = HelpTopic.main});

  final HelpTopic topic;

  @override
  State<HelpScreen> createState() => _HelpScreenState();
}

class _HelpScreenState extends State<HelpScreen> {
  /// 每個 section 一把 key，導覽靠它捲過去。
  late List<GlobalKey> _sectionKeys;

  @override
  void initState() {
    super.initState();
    _rebuildKeys();
  }

  @override
  void didUpdateWidget(covariant HelpScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.topic != widget.topic) _rebuildKeys();
  }

  void _rebuildKeys() {
    final doc = kHelpDocs[widget.topic]!;
    _sectionKeys = List.generate(doc.sections.length, (_) => GlobalKey());
  }

  Future<void> _jumpTo(int index) async {
    final ctx = _sectionKeys[index].currentContext;
    if (ctx == null) return;
    await Scrollable.ensureVisible(
      ctx,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
      alignment: 0.02,
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    final doc = kHelpDocs[widget.topic]!;
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
        title: Text('說明', style: UepText.pageTitle(color: s.inkTitle)),
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          // 寬視窗左邊擺一欄分節導覽；窄的時候收成頂部一列水平 chip
          final wide = constraints.maxWidth >= 900;
          final content = ListView(
            padding: const EdgeInsets.all(32),
            children: [
              MonoLabel('說明'),
              const SizedBox(height: 6),
              Text(doc.title,
                  style: UepText.pageTitle(color: s.inkTitle)),
              const SizedBox(height: 22),
              if (!wide) ...[
                _NavChips(doc: doc, onTap: _jumpTo),
                const SizedBox(height: 18),
              ],
              for (var i = 0; i < doc.sections.length; i++) ...[
                _SectionCard(
                  key: _sectionKeys[i],
                  section: doc.sections[i],
                ),
                if (i != doc.sections.length - 1) const SizedBox(height: 14),
              ],
            ],
          );
          if (!wide) return content;
          return Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: kPageMaxWidth + 200),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 200,
                    child: _NavColumn(doc: doc, onTap: _jumpTo),
                  ),
                  Expanded(
                    child: ConstrainedBox(
                      constraints:
                          const BoxConstraints(maxWidth: kPageMaxWidth),
                      child: content,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// 寬視窗的左欄導覽。
class _NavColumn extends StatelessWidget {
  const _NavColumn({required this.doc, required this.onTap});

  final HelpDoc doc;
  final void Function(int index) onTap;

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 38, 8, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          MonoLabel('分節'),
          const SizedBox(height: 10),
          for (var i = 0; i < doc.sections.length; i++)
            InkWell(
              onTap: () => onTap(i),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 7),
                child: Row(children: [
                  Icon(doc.sections[i].icon, size: 14, color: s.inkMute),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      doc.sections[i].title,
                      style: UepText.sans(size: 14, color: s.inkSoft),
                    ),
                  ),
                ]),
              ),
            ),
        ],
      ),
    );
  }
}

/// 窄視窗的頂部導覽。
class _NavChips extends StatelessWidget {
  const _NavChips({required this.doc, required this.onTap});

  final HelpDoc doc;
  final void Function(int index) onTap;

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (var i = 0; i < doc.sections.length; i++)
          InkWell(
            onTap: () => onTap(i),
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                border: Border.all(color: s.line),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(doc.sections[i].icon, size: 13, color: s.inkMute),
                const SizedBox(width: 6),
                Text(doc.sections[i].title,
                    style: UepText.sans(size: 13.5, color: s.inkSoft)),
              ]),
            ),
          ),
      ],
    );
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({super.key, required this.section});

  final HelpSection section;

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
      decoration: BoxDecoration(
        color: s.bgSoft,
        border: Border.all(color: s.line),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(section.icon, size: 16, color: s.inkSoft),
            const SizedBox(width: 8),
            Text(section.title,
                style: UepText.sectionTitle(color: s.inkTitle)),
            // 小標中文化後有幾節的 label 與標題同字，重複列出只是雜訊
            if (section.label != section.title) ...[
              const SizedBox(width: 10),
              MonoLabel(section.label, color: s.inkMute.withValues(alpha: .7)),
            ],
          ]),
          const SizedBox(height: 10),
          for (final item in section.items)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: _ItemRow(item: item),
            ),
        ],
      ),
    );
  }
}

class _ItemRow extends StatelessWidget {
  const _ItemRow({required this.item});

  final HelpItem item;

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    final body = UepText.serif(size: 14.5, color: s.ink, height: 1.75);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 5),
          child: Container(width: 10, height: 1, color: s.lineStrong),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text.rich(
            TextSpan(children: [
              for (final chunk in item.chunks)
                if (chunk.isCode)
                  WidgetSpan(
                    alignment: PlaceholderAlignment.middle,
                    child: _CodeChip(text: chunk.text),
                  )
                else
                  TextSpan(text: chunk.text),
            ]),
            style: body,
          ),
        ),
      ],
    );
  }
}

/// 行內 token（快捷鍵、語法、位址）的小 chip。
class _CodeChip extends StatelessWidget {
  const _CodeChip({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 2),
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: s.bgCard,
        border: Border.all(color: s.line),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(text, style: UepText.code(size: 12, color: s.ink, height: 1.3)),
    );
  }
}
