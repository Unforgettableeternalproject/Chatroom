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
            HelpChunk.code('@agents'),
            HelpChunk.text('、'),
            HelpChunk.code('@humans'),
            HelpChunk.text('、'),
            HelpChunk.code('@all'),
            HelpChunk.text(' 一次提及一整群，送出時展開成當下在房裡的實名。'),
          ]),
          HelpItem([HelpChunk.text('那一類人不在房裡時會展開成空，App 會講出來——沒有人被通知到，訊息還是送出去了。')]),
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
          HelpItem([HelpChunk.text('釘選是整間房共用的：誰釘的所有人都看得到，取消釘選也一樣。釘選牆只收還在的訊息，原訊息被刪就不在牆上。')]),
          HelpItem([HelpChunk.text('「匯出對話紀錄」把整間房存成一個檔，包含全部訊息與附件資訊——那是一次外流，存到哪裡自己負責。')]),
          HelpItem([HelpChunk.text('匯出要有這間房的成員身分；時間一律是 Hub 給的 UTC 原字串，不轉本地時間。')]),
          HelpItem([HelpChunk.text('封存後只能看不能寫；封存一段時間後 Hub 會把房間連同訊息與附件永久刪除。要留底就在刪除前匯出。')]),
        ],
      ),
      HelpSection(
        label: '成員',
        title: '成員與在線',
        icon: Icons.group_outlined,
        items: [
          HelpItem([HelpChunk.text('名字旁的「派工中」＝這個成員是某一筆派工帶進房的。Hub 不會把它當閒置掃掉，所以那一列沒有倒數。')]),
          HelpItem([HelpChunk.text('派工結束它會自己離房；沒離開的話 Hub 也會在 run 收場時把它移出——不必自己去踢。')]),
          HelpItem([HelpChunk.text('一般 agent 超過兩分鐘沒動作，那一列會印閒置多久、最快多久後被移出。被移出的人重新指派一次就會回來。')]),
          HelpItem([
            HelpChunk.text('agent 要做一件很久的事時可以自己掛 '),
            HelpChunk.code('chatroom_hold'),
            HelpChunk.text(' 免掃，但 hold 有到期時間，不是無限期。'),
          ]),
          HelpItem([HelpChunk.text('隱藏與重點標記只動我這台裝置的視圖，移出成員才是動到所有人。')]),
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
        label: '素材',
        title: '階段素材',
        icon: Icons.attachment_outlined,
        items: [
          HelpItem([HelpChunk.text('素材掛在「階段」上，那個階段底下的每一張卡與每一筆派工共用，所以入口在階段標題列，不在某一張卡裡面。')]),
          HelpItem([HelpChunk.text('階段標題列上的「素材 N」點開才是清單；沒有素材時那個數字整個不顯示。')]),
          HelpItem([HelpChunk.text('「新增素材」會把檔案上傳到目前這間聊天室再掛上階段——沒有房的時候掛不了。')]),
          HelpItem([HelpChunk.text('一次選多個檔不問備註，直接整批掛上去；只選一個檔才會問一句「這份素材是什麼」，可以留白。')]),
          HelpItem([HelpChunk.text('備註之後在清單上逐列編輯，改成空字串就是把備註清掉。')]),
          HelpItem([HelpChunk.text('點檔名開檢視：圖片在 App 內看，其餘交給系統預設程式開。')]),
          HelpItem([HelpChunk.text('「卸除」只把這份素材從這個階段拿掉，聊天室裡原本那則附件還在。別人可能正在用，所以會問一次。')]),
          HelpItem([HelpChunk.text('agent 讀得到素材列表與備註——要它看的規格、截圖、草稿放這裡，比貼在聊天裡讓它自己翻可靠。')]),
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
          HelpItem([
            HelpChunk.text('開工前執行器會先 '),
            HelpChunk.code('fetch'),
            HelpChunk.text(' 並用 '),
            HelpChunk.code('pull --ff-only'),
            HelpChunk.text(' 把常駐工作樹快轉到最新——工作樹是跨 run 共用的，不同步就等於在上一輪的舊基礎上動工。'),
          ]),
          HelpItem([HelpChunk.text('工作樹有未提交變更時不同步，照現況執行並在收工摘要裡講明；分支已經分岔而快轉不了則整筆派工直接失敗，要先自己處理。')]),
          HelpItem([HelpChunk.text('一次派工動得到那個專案底下的所有 repo，不只你選的那個。每個 repo 都必須停在自己的允許分支上，有一個不合就不開工。')]),
          HelpItem([HelpChunk.text('agent 每完成一個可交付的小步驟就在房裡回報一次——看回報就知道它走到哪，不必去翻卡。')]),
          HelpItem([HelpChunk.text('在房裡 @ 它就能補指示，但訊息是在它下一次工具呼叫之前才送到，不會打斷手上那一步。')]),
          HelpItem([HelpChunk.text('「請收尾」是軟停止：它把目前這一步做完、寫完摘要再結束。五分鐘內還沒結束才會被硬取消。')]),
          HelpItem([HelpChunk.text('「取消」是執行器直接殺進程，寫到一半的東西就停在那裡。趕時間才用它，否則用請收尾。')]),
          HelpItem([HelpChunk.text('上下文用滿會觸發交接：它把已做／未做／下一步寫在卡上並釋放認領，下一輪的 brief 直接接上那份摘要。')]),
          HelpItem([HelpChunk.text('瀏覽器實機測試除非派工簡述明確要求，否則不是交付門檻——沒跑不影響這一輪算不算完成。')]),
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
        label: '連線',
        title: '連線',
        icon: Icons.settings_ethernet,
        items: [
          HelpItem([HelpChunk.text('拿到邀請碼就按「貼上邀請碼」，Hub 位址與 token 會一起填好——手動兩個欄位各填一次容易配錯對。')]),
          HelpItem([
            HelpChunk.text('Hub 位址是那台機器連得到的網址（例如 '),
            HelpChunk.code('http://127.0.0.1:8787'),
            HelpChunk.text('）。主持人綁 '),
            HelpChunk.code('0.0.0.0'),
            HelpChunk.text(' 時，要填的是他那台機器的 IP。'),
          ]),
          HelpItem([HelpChunk.text('API token 填人類 token；沒設 token 的 Hub 才留空。改完要按「儲存設定」，連線與個人化兩頁共用同一顆。')]),
          HelpItem([HelpChunk.text('「測試連線」只驗這台機器到 Hub 這一段：它綠了不代表別人連得到，那是主持人那邊的事。')]),
          HelpItem([HelpChunk.text('「App 版本」那串在這頁最底下，回報問題時先附上它。')]),
        ],
      ),
      HelpSection(
        label: '邀請',
        title: '邀請與 token',
        icon: Icons.vpn_key_outlined,
        items: [
          HelpItem([HelpChunk.text('邀請成員在連線頁底下：產生一份邀請碼給對方，之後可以單獨撤銷，不必換掉所有人的 token。')]),
          HelpItem([HelpChunk.text('邀請碼等同密碼，用私訊給，不要貼在公開頻道。')]),
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
        label: '視覺',
        title: '視覺',
        icon: Icons.palette_outlined,
        items: [
          HelpItem([HelpChunk.text('深色主題這裡與標題列那顆切的是同一個開關。')]),
          HelpItem([HelpChunk.text('字級五檔（極小／小／中 (預設)／大／特大）選了立刻套用到整個 App，不必重開。')]),
          HelpItem([HelpChunk.text('「極小」是半個字級，實際上讀不了——它留著是個玩笑，要縮小從「小」開始試。')]),
          HelpItem([HelpChunk.text('語言還沒做，所以這頁沒有語言選項。')]),
        ],
      ),
      HelpSection(
        label: '個人化',
        title: '個人化',
        icon: Icons.person_outline,
        items: [
          HelpItem([HelpChunk.text('顯示名稱是進房時用的名字，留空則由 Hub 隨機指派代稱。房內名字不能重複。')]),
          HelpItem([HelpChunk.text('本機裝置識別是這台機器的身分。「重新產生」等於換一個人：原本的成員身分、未讀與管控權都接不回來。')]),
          HelpItem([HelpChunk.text('系統通知分「所有訊息／僅提及我時／關閉」，改完立刻生效，但仍然只在 App 開著時才會發。')]),
          HelpItem([HelpChunk.text('「轉送通知給 Codex」會把提及與 Board 變動送到本機 Codex session；thread id 留空就用預設那條。')]),
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
          HelpItem([HelpChunk.text('不要看工具說明結尾那個版本：宿主端會快取，同一刻三支工具可能報三個不同的數字。')]),
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
          HelpItem([HelpChunk.text('只有裝了 host-kit 或 mcp-kit 的機器看得到這個入口。兩個都裝就分成「Hub 主持」與「Agent 接入」兩頁。')]),
          HelpItem([HelpChunk.text('狀態那三盞燈是進程、對外綁定、認證。空心灰圈＝沒有資訊，不是警告，不用去修。')]),
          HelpItem([HelpChunk.text('「本機打得到」不等於別台機器連得到——綠燈底下的那句備註要讀。')]),
          HelpItem([HelpChunk.text('連線資訊那一區是要發給成員的東西：Hub 位址、人類 token、Agent token。')]),
          HelpItem([HelpChunk.text('兩把 token 別發錯：Agent token 開不了主持人模式也發不了邀請，人類拿到它會看到像「這台 Hub 不是你主持的」的錯誤。')]),
          HelpItem([
            HelpChunk.text('綁在 '),
            HelpChunk.code('0.0.0.0'),
            HelpChunk.text(' 時，發給成員的位址要換成他們連得到的 IP。'),
          ]),
          HelpItem([HelpChunk.text('Hub 是本機的伺服器進程，關掉 App 不會停 Hub。「停止 Hub」殺掉所有 Hub 進程，包含自己在前景視窗開的那個。')]),
          HelpItem([HelpChunk.text('自動啟動：一般權限註冊＝登入時自啟；以系統管理員執行 App 再註冊＝開機自啟。')]),
          HelpItem([HelpChunk.text('「安裝位置」是 kit 的根目錄，要手動改設定或看 log 時從那裡進去。')]),
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
          HelpItem([HelpChunk.text('換 token：重啟 Hub 後才生效，之後每個成員都要換成新的，agent 那邊的 kit 也要一起換。')]),
        ],
      ),
      HelpSection(
        label: '接入',
        title: 'Agent 接入',
        icon: Icons.smart_toy_outlined,
        items: [
          HelpItem([HelpChunk.text('接入狀態的兩盞燈只回答「這台機器連不連得到 Hub」與「這把 token 認不認得」。')]),
          HelpItem([HelpChunk.text('它答不了「agent 認得那些工具了嗎」——那要看 agent 進程載了哪一份 bridge，App 看不到。')]),
          HelpItem([
            HelpChunk.text('要確認跑著的是哪一份，讓 agent 呼叫 '),
            HelpChunk.code('chatroom_join'),
            HelpChunk.text(' 並看回傳的 '),
            HelpChunk.code('bridge.commit'),
            HelpChunk.text('；對不上就重開那個 agent。'),
          ]),
        ],
      ),
      HelpSection(
        label: '執行器',
        title: '執行器（runner）',
        icon: Icons.terminal,
        items: [
          HelpItem([HelpChunk.text('執行器是替派工跑 agent 的那個常駐程式，目前沒有 UI 分頁，全部設定都在設定檔裡改。')]),
          HelpItem([
            HelpChunk.text('設定檔在 '),
            HelpChunk.code('%LOCALAPPDATA%\\UEP\\Chatroom\\runner\\config.json'),
            HelpChunk.text('，可以照 '),
            HelpChunk.code('runner/config.example.json'),
            HelpChunk.text(' 複製一份再改。'),
          ]),
          HelpItem([
            HelpChunk.code('projects'),
            HelpChunk.text(' 是白名單：沒列在裡面的專案派不了工，Hub 會在建單時就擋下來。'),
          ]),
          HelpItem([
            HelpChunk.code('repos'),
            HelpChunk.text(' 列這個專案底下每一個 repo 的本機路徑。一次派工動得到全部，所以漏掉的那個 agent 碰不到。'),
          ]),
          HelpItem([
            HelpChunk.code('allowed_branches'),
            HelpChunk.text(' 是這個 repo 准許動工的分支。工作樹停在清單外的分支時整筆派工直接失敗，而不是幫你切過去。'),
          ]),
          HelpItem([
            HelpChunk.code('default_repo'),
            HelpChunk.text(' 是建單沒指定時的主工作目錄，必須是 '),
            HelpChunk.code('repos'),
            HelpChunk.text(' 裡真的有的那個名字，否則設定讀不起來。'),
          ]),
          HelpItem([
            HelpChunk.code('context_window_tokens'),
            HelpChunk.text(' 是判斷何時該交接的依據（預設 1000000）。填得比模型實際的視窗大，交接會來不及。'),
          ]),
          HelpItem([HelpChunk.text('設定檔是啟動時讀的：改完要重啟執行器才算數。')]),
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
