import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/uep_theme.dart';
import '../../core/theme/uep_tokens.dart';
import '../../l10n/l10n.dart';
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

/// 三份說明文件。文案全部走 l10n，所以這裡是函式而不是 const map——
/// 語言換了要跟著換，內容就不能在編譯期定死。
Map<HelpTopic, HelpDoc> helpDocs(AppLocalizations l10n) => {
  HelpTopic.main: HelpDoc(
    title: l10n.helpDocMainTitle,
    sections: [
      HelpSection(
        label: l10n.helpSecChatLabel,
        title: l10n.helpSecChatTitle,
        icon: Icons.forum_outlined,
        items: [
          HelpItem([
            HelpChunk.code(l10n.helpChatMentionSyntax),
            HelpChunk.text(l10n.helpChat1a),
            HelpChunk.code(l10n.helpChatCardSyntax),
            HelpChunk.text(l10n.helpChat1b),
          ]),
          HelpItem([
            const HelpChunk.code('@agents'),
            HelpChunk.text(l10n.helpChat2a),
            const HelpChunk.code('@humans'),
            HelpChunk.text(l10n.helpChat2a),
            const HelpChunk.code('@all'),
            HelpChunk.text(l10n.helpChat2c),
          ]),
          HelpItem([HelpChunk.text(l10n.helpChat3)]),
          HelpItem([
            const HelpChunk.code('Enter'),
            HelpChunk.text(l10n.helpChat4a),
            const HelpChunk.code('Shift+Enter'),
            HelpChunk.text(l10n.helpChat4b),
            const HelpChunk.code('↑↓'),
            HelpChunk.text(l10n.helpChat4c),
          ]),
          HelpItem([HelpChunk.text(l10n.helpChat5)]),
          HelpItem([HelpChunk.text(l10n.helpChat6)]),
          HelpItem([HelpChunk.text(l10n.helpChat7)]),
          HelpItem([HelpChunk.text(l10n.helpChat8)]),
          HelpItem([HelpChunk.text(l10n.helpChat9)]),
          HelpItem([HelpChunk.text(l10n.helpChat10)]),
        ],
      ),
      HelpSection(
        label: l10n.helpSecMemberLabel,
        title: l10n.helpSecMemberTitle,
        icon: Icons.group_outlined,
        items: [
          HelpItem([HelpChunk.text(l10n.helpMember1)]),
          HelpItem([HelpChunk.text(l10n.helpMember2)]),
          HelpItem([HelpChunk.text(l10n.helpMember3)]),
          HelpItem([
            HelpChunk.text(l10n.helpMember4a),
            const HelpChunk.code('chatroom_hold'),
            HelpChunk.text(l10n.helpMember4b),
          ]),
          HelpItem([HelpChunk.text(l10n.helpMember5)]),
        ],
      ),
      HelpSection(
        label: l10n.helpSecBoardLabel,
        title: l10n.helpSecBoardTitle,
        icon: Icons.dashboard_outlined,
        items: [
          HelpItem([HelpChunk.text(l10n.helpBoard1)]),
          HelpItem([HelpChunk.text(l10n.helpBoard2)]),
          HelpItem([HelpChunk.text(l10n.helpBoard3)]),
          HelpItem([
            HelpChunk.text(l10n.helpBoard4a),
            const HelpChunk.code('SCRATCHPAD'),
            HelpChunk.text(l10n.helpBoard4b),
          ]),
          HelpItem([HelpChunk.text(l10n.helpBoard5)]),
        ],
      ),
      HelpSection(
        label: l10n.helpSecAssetLabel,
        title: l10n.helpSecAssetTitle,
        icon: Icons.attachment_outlined,
        items: [
          HelpItem([HelpChunk.text(l10n.helpAsset1)]),
          HelpItem([HelpChunk.text(l10n.helpAsset2)]),
          HelpItem([HelpChunk.text(l10n.helpAsset3)]),
          HelpItem([HelpChunk.text(l10n.helpAsset4)]),
          HelpItem([HelpChunk.text(l10n.helpAsset5)]),
          HelpItem([HelpChunk.text(l10n.helpAsset6)]),
          HelpItem([HelpChunk.text(l10n.helpAsset7)]),
          HelpItem([HelpChunk.text(l10n.helpAsset8)]),
        ],
      ),
      HelpSection(
        label: l10n.helpSecOpsLabel,
        title: l10n.helpSecOpsTitle,
        icon: Icons.play_circle_outline,
        items: [
          HelpItem([
            HelpChunk.text(l10n.helpOps1a),
            const HelpChunk.code('projects'),
            HelpChunk.text(l10n.helpOps1b),
          ]),
          HelpItem([
            HelpChunk.text(l10n.helpOps2a),
            const HelpChunk.code('fetch'),
            HelpChunk.text(l10n.helpOps2b),
            const HelpChunk.code('pull --ff-only'),
            HelpChunk.text(l10n.helpOps2c),
          ]),
          HelpItem([HelpChunk.text(l10n.helpOps3)]),
          HelpItem([HelpChunk.text(l10n.helpOps4)]),
          HelpItem([HelpChunk.text(l10n.helpOps5)]),
          HelpItem([HelpChunk.text(l10n.helpOps6)]),
          HelpItem([HelpChunk.text(l10n.helpOps7)]),
          HelpItem([HelpChunk.text(l10n.helpOps8)]),
          HelpItem([HelpChunk.text(l10n.helpOps9)]),
          HelpItem([HelpChunk.text(l10n.helpOps10)]),
          HelpItem([HelpChunk.text(l10n.helpOps11)]),
        ],
      ),
      HelpSection(
        label: l10n.helpSecNotifyLabel,
        title: l10n.helpSecNotifyTitle,
        icon: Icons.notifications_outlined,
        items: [
          HelpItem([HelpChunk.text(l10n.helpNotify1)]),
        ],
      ),
    ],
  ),
  HelpTopic.settings: HelpDoc(
    title: l10n.helpDocSettingsTitle,
    sections: [
      HelpSection(
        label: l10n.settingsTabConnection,
        title: l10n.settingsTabConnection,
        icon: Icons.settings_ethernet,
        items: [
          HelpItem([HelpChunk.text(l10n.helpConn1)]),
          HelpItem([
            HelpChunk.text(l10n.helpConn2a),
            const HelpChunk.code('http://127.0.0.1:8787'),
            HelpChunk.text(l10n.helpConn2b),
            const HelpChunk.code('0.0.0.0'),
            HelpChunk.text(l10n.helpConn2c),
          ]),
          HelpItem([HelpChunk.text(l10n.helpConn3)]),
          HelpItem([HelpChunk.text(l10n.helpConn4)]),
          HelpItem([HelpChunk.text(l10n.helpConn5)]),
        ],
      ),
      HelpSection(
        label: l10n.helpSecInviteLabel,
        title: l10n.helpSecInviteTitle,
        icon: Icons.vpn_key_outlined,
        items: [
          HelpItem([HelpChunk.text(l10n.helpInvite1)]),
          HelpItem([HelpChunk.text(l10n.helpInvite2)]),
          HelpItem([HelpChunk.text(l10n.helpInvite3)]),
          HelpItem([
            HelpChunk.text(l10n.helpInvite4a),
            const HelpChunk.code('Agent token'),
            HelpChunk.text(l10n.helpInvite4b),
          ]),
          HelpItem([HelpChunk.text(l10n.helpInvite5)]),
        ],
      ),
      HelpSection(
        label: l10n.settingsTabVisual,
        title: l10n.settingsTabVisual,
        icon: Icons.palette_outlined,
        items: [
          HelpItem([HelpChunk.text(l10n.helpVisual1)]),
          HelpItem([HelpChunk.text(l10n.helpVisual2)]),
          HelpItem([HelpChunk.text(l10n.helpVisual3)]),
          HelpItem([HelpChunk.text(l10n.helpVisualLanguage)]),
        ],
      ),
      HelpSection(
        label: l10n.settingsTabPersonal,
        title: l10n.settingsTabPersonal,
        icon: Icons.person_outline,
        items: [
          HelpItem([HelpChunk.text(l10n.helpPersonal1)]),
          HelpItem([HelpChunk.text(l10n.helpPersonal2)]),
          HelpItem([HelpChunk.text(l10n.helpPersonal3)]),
          HelpItem([HelpChunk.text(l10n.helpPersonal4)]),
        ],
      ),
      HelpSection(
        label: l10n.helpSecVersionLabel,
        title: l10n.helpSecVersionTitle,
        icon: Icons.verified_outlined,
        items: [
          HelpItem([HelpChunk.text(l10n.helpVersionApp1)]),
          HelpItem([HelpChunk.text(l10n.helpVersionApp2)]),
          HelpItem([
            HelpChunk.text(l10n.helpVersionApp3a),
            const HelpChunk.code('chatroom_join'),
            HelpChunk.text(l10n.helpVersionApp3b),
            const HelpChunk.code('bridge.commit'),
            HelpChunk.text(l10n.helpVersionApp3c),
          ]),
          HelpItem([HelpChunk.text(l10n.helpVersionApp4)]),
        ],
      ),
    ],
  ),
  HelpTopic.host: HelpDoc(
    title: l10n.helpDocHostTitle,
    sections: [
      HelpSection(
        label: l10n.helpSecMachineLabel,
        title: l10n.hostConsoleTitle,
        icon: Icons.dns_outlined,
        items: [
          HelpItem([HelpChunk.text(l10n.helpMachine1)]),
          HelpItem([HelpChunk.text(l10n.helpMachine2)]),
          HelpItem([HelpChunk.text(l10n.helpMachine3)]),
          HelpItem([HelpChunk.text(l10n.helpMachine4)]),
          HelpItem([HelpChunk.text(l10n.helpMachine5)]),
          HelpItem([
            HelpChunk.text(l10n.helpMachine6a),
            const HelpChunk.code('0.0.0.0'),
            HelpChunk.text(l10n.helpMachine6b),
          ]),
          HelpItem([HelpChunk.text(l10n.helpMachine7)]),
          HelpItem([HelpChunk.text(l10n.helpMachine8)]),
          HelpItem([HelpChunk.text(l10n.helpMachine9)]),
        ],
      ),
      HelpSection(
        label: l10n.helpSecTunnelLabel,
        title: l10n.helpSecTunnelTitle,
        icon: Icons.cloud_outlined,
        items: [
          HelpItem([HelpChunk.text(l10n.helpTunnel1)]),
          HelpItem([HelpChunk.text(l10n.helpTunnel2)]),
          HelpItem([
            HelpChunk.text(l10n.helpTunnel3a),
            const HelpChunk.code('attachments/'),
            HelpChunk.text(l10n.helpTunnel3b),
            const HelpChunk.code('backups\\'),
            HelpChunk.text(l10n.helpTunnel3c),
          ]),
          HelpItem([HelpChunk.text(l10n.helpTunnel4)]),
        ],
      ),
      HelpSection(
        label: l10n.helpSecLinkLabel,
        title: l10n.helpSecLinkTitle,
        icon: Icons.smart_toy_outlined,
        items: [
          HelpItem([HelpChunk.text(l10n.helpLink1)]),
          HelpItem([HelpChunk.text(l10n.helpLink2)]),
          HelpItem([
            HelpChunk.text(l10n.helpLink3a),
            const HelpChunk.code('chatroom_join'),
            HelpChunk.text(l10n.helpLink3b),
            const HelpChunk.code('bridge.commit'),
            HelpChunk.text(l10n.helpLink3c),
          ]),
        ],
      ),
      HelpSection(
        label: l10n.helpSecRunnerLabel,
        title: l10n.helpSecRunnerTitle,
        icon: Icons.terminal,
        items: [
          HelpItem([HelpChunk.text(l10n.helpRunner1)]),
          HelpItem([
            HelpChunk.text(l10n.helpRunner2a),
            const HelpChunk.code(
                '%LOCALAPPDATA%\\UEP\\Chatroom\\runner\\config.json'),
            HelpChunk.text(l10n.helpRunner2b),
            const HelpChunk.code('runner/config.example.json'),
            HelpChunk.text(l10n.helpRunner2c),
          ]),
          HelpItem([
            const HelpChunk.code('projects'),
            HelpChunk.text(l10n.helpRunner3a),
          ]),
          HelpItem([
            const HelpChunk.code('repos'),
            HelpChunk.text(l10n.helpRunner4a),
          ]),
          HelpItem([
            const HelpChunk.code('allowed_branches'),
            HelpChunk.text(l10n.helpRunner5a),
          ]),
          HelpItem([
            const HelpChunk.code('default_repo'),
            HelpChunk.text(l10n.helpRunner6a),
            const HelpChunk.code('repos'),
            HelpChunk.text(l10n.helpRunner6b),
          ]),
          HelpItem([
            const HelpChunk.code('context_window_tokens'),
            HelpChunk.text(l10n.helpRunner7a),
          ]),
          HelpItem([HelpChunk.text(l10n.helpRunner8)]),
        ],
      ),
      HelpSection(
        label: l10n.helpSecVersionLabel,
        title: l10n.helpSecVersionTitle,
        icon: Icons.verified_outlined,
        items: [
          HelpItem([HelpChunk.text(l10n.helpVersionHub1)]),
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

  // 分節數量要先拿到文件才知道，而文件現在要 l10n——所以在
  // didChangeDependencies 建 key，那裡才查得到 Localizations。
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _rebuildKeys();
  }

  @override
  void didUpdateWidget(covariant HelpScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.topic != widget.topic) _rebuildKeys();
  }

  void _rebuildKeys() {
    final doc = helpDocs(AppLocalizations.of(context))[widget.topic]!;
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
    final l10n = AppLocalizations.of(context);
    final doc = helpDocs(l10n)[widget.topic]!;
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
        title:
            Text(l10n.helpTooltip, style: UepText.pageTitle(color: s.inkTitle)),
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          // 寬視窗左邊擺一欄分節導覽；窄的時候收成頂部一列水平 chip
          final wide = constraints.maxWidth >= 900;
          final content = ListView(
            padding: const EdgeInsets.all(32),
            children: [
              MonoLabel(l10n.helpTooltip),
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
          MonoLabel(AppLocalizations.of(context).helpNavLabel),
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
