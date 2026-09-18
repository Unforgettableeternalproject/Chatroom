import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/uep_theme.dart';
import '../../core/theme/uep_tokens.dart';
import '../../widgets/markdown_body.dart';

/// 手冊。
///
/// 各畫面上不放介紹性文字，需要解釋的東西集中在這裡——功能底下逐句加註
/// 會把每個畫面都變成教學，而這個 App 的使用者是進階使用者。
///
/// 內容只講「怎麼用」，不講原理。要加東西之前先問：不知道這件事的人會做
/// 錯什麼？答不出來就不要寫。
const kHelpMarkdown = '''
# 說明

## 聊天室

`@名字` 提及成員，`#[標題]` 指涉任務卡。Enter 送出，Shift+Enter 換行，↑↓ 叫回歷史。
檔案可以拖進輸入框，也可以直接貼上截圖。

私人聊天室不會出現在別人的列表裡，必須受邀才能加入。

封存後只能看不能寫；封存一段時間後 Hub 會把房間連同訊息與附件永久刪除。

## 任務板

板不屬於任何一間房，一塊板可以掛在好幾間聊天室上。解除掛接不會刪掉板。

結構是週期 → 階段 → 任務。所有階段收尾後才能送審，未分類的卡也要先收尾。

「搬到別處」會在目標階段建立一張新卡，原本那張標成「已搬走」。

想法板（SCRATCHPAD）放還沒拆成卡的東西；agent 讀得到、也能留意見，但改不動你寫的內容。

板的 owner 決定誰能編輯。在同一間房裡不會自動成為板的協作者。

## 派工

派工要有執行器在線，而且目標專案在它的 projects 白名單裡，否則 Hub 會擋下建單。

推送會先比對待推的 commit 與畫面上看到的是否一致，不一致就不推並回報。

## 邀請與 token

邀請碼等同密碼，用私訊給，不要貼在公開頻道。每份邀請可以單獨撤銷，不必換掉所有人的 token。

人類 token 與 Agent token 是兩把：只有人類 token 開得了主持人模式、發得了邀請。
Agent token 填進 mcp-kit 安裝器的「Agent token」欄位。

把成員移出聊天室會撤銷他當初用的那張邀請碼，與他共用同一張的人會一起斷線。

## 這台機器（主控台）

只有裝了 host-kit 或 mcp-kit 的機器看得到這個入口。

- **Hub**：本機的伺服器進程。關掉 App 不會停 Hub。
- **自動啟動**：一般權限註冊＝登入時自啟；以系統管理員執行 App 再註冊＝開機自啟。
- **隧道**：把這台 Hub 放到公網上，擋在前面的只有 token。
  一次只能有一條，要換網址先關閉再開。網址每次重開都會變，換過之後邀請碼要重發。
- **備份**：資料庫與 attachments/ 一起收進 backups\\。還原前 Hub 必須先停止，
  而且會自動先備份現況。
- **換 token**：重啟 Hub 後才生效，之後每個成員都要換成新的。

綁在 `0.0.0.0` 時，發給成員的位址要換成他們連得到的 IP。

## 版本

橫幅說「App 版本較舊」就更新 App，說「Hub 版本較舊」就更新 Hub。
兩邊的 commit 在設定頁與橫幅的 tooltip 上，回報問題時附上。

要確認 agent 用的是哪一份 bridge，讓它呼叫 `chatroom_join`，比對回傳的 `bridge.commit`。

## 通知

系統通知只在 App 開著時發，關閉期間的訊息不會補發，回來後靠未讀紅點找。

「轉送通知給 Codex」會把提及與 Board 變動送到本機 Codex session。
''';

class HelpScreen extends StatelessWidget {
  const HelpScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
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
        title: Text('說明', style: UepText.display(size: 22, color: s.inkTitle)),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: ListView(
            padding: const EdgeInsets.all(32),
            children: const [UepMarkdownBody(data: kHelpMarkdown)],
          ),
        ),
      ),
    );
  }
}
