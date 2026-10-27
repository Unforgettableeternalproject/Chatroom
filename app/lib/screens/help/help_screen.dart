import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/uep_theme.dart';
import '../../core/theme/uep_tokens.dart';
import '../../l10n/l10n.dart';
import '../../widgets/help_blocks.dart';
import '../../widgets/kind_badge.dart';

export '../../widgets/help_blocks.dart'
    show HelpCalloutTone, HelpCardData, HelpChunk, HelpStepData;

/// 手冊。
///
/// 各畫面上不放介紹性文字，需要解釋的東西集中在這裡——功能底下逐句加註
/// 會把每個畫面都變成教學，而這個 App 的使用者是進階使用者。
///
/// 內容只講「怎麼用」，不講原理。要加東西之前先問：不知道這件事的人會做
/// 錯什麼？答不出來就不要寫。
///
/// 版面以區塊組成（卡片、表格、步驟、提示／注意、條目清單），一個概念用
/// 一種區塊講：並列的東西用卡片，「甲對應乙」用表格，有先後用步驟，
/// 容易踩的地方用提示／注意。長段落不寫。
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

/// 一條說明。一到兩句，太長就拆成兩條。
///
/// 慣例：**第一個 chunk 是 `bold` 就當這條的小標**，單獨一行，後面接一句
/// 說明。「一句話結論＋一句話原因」比一句塞三件事好讀，而且掃得到。
@immutable
class HelpItem {
  const HelpItem(this.chunks);

  final List<HelpChunk> chunks;

  /// 首個 chunk 是粗體 ⇒ 那段是小標，其餘是內文。
  bool get hasLead => chunks.isNotEmpty && chunks.first.isBold;
}

/// 一節裡的一個區塊。
sealed class HelpBlock {
  const HelpBlock();
}

/// 條目清單（短橫線開頭）。
class HelpItemsBlock extends HelpBlock {
  const HelpItemsBlock(this.items, {this.groups = const {}});

  final List<HelpItem> items;

  /// 分組：index → 小標，那一條之前插一行。條目多的清單才需要。
  final Map<int, String> groups;
}

/// 並排的資訊卡片。
class HelpCardsBlock extends HelpBlock {
  const HelpCardsBlock(this.cards);

  final List<HelpCardData> cards;
}

/// 表格。每列的欄數必須等於表頭的欄數。
class HelpTableBlock extends HelpBlock {
  const HelpTableBlock({required this.headers, required this.rows});

  final List<String> headers;
  final List<List<String>> rows;
}

/// 提示／注意。
class HelpCalloutBlock extends HelpBlock {
  const HelpCalloutBlock(this.text, {this.tone = HelpCalloutTone.tip});

  final String text;
  final HelpCalloutTone tone;
}

/// 編號步驟。
class HelpStepsBlock extends HelpBlock {
  const HelpStepsBlock(this.steps);

  final List<HelpStepData> steps;
}

/// 一小段說明文字（區塊之間的銜接用，一兩句）。
class HelpParagraphBlock extends HelpBlock {
  const HelpParagraphBlock(this.text);

  final String text;
}

@immutable
class HelpSection {
  const HelpSection({
    required this.label,
    required this.title,
    required this.icon,
    required this.blocks,
    this.intro,
  });

  /// 導覽上的 mono 小標。
  final String label;
  final String title;
  final IconData icon;

  /// 標題底下的一句導語。
  final String? intro;
  final List<HelpBlock> blocks;
}

@immutable
class HelpDoc {
  const HelpDoc({required this.title, required this.sections});

  final String title;
  final List<HelpSection> sections;
}

/// 三份說明文件。文案全部走 l10n，所以這裡是函式而不是 const map——
/// 語言換了要跟著換，內容就不能在編譯期定死。
Map<HelpTopic, HelpDoc> helpDocs(AppLocalizations l10n) {
  HelpCardData card(String tag, String title, String sub, String body) =>
      HelpCardData(tag: tag, title: title, subtitle: sub, body: body);

  return {
    HelpTopic.main: HelpDoc(
      title: l10n.helpDocMainTitle,
      sections: [
        HelpSection(
          label: l10n.helpSecOverviewLabel,
          title: l10n.helpSecOverviewTitle,
          icon: Icons.explore_outlined,
          intro: l10n.helpSecOverviewIntro,
          blocks: [
            HelpCardsBlock([
              card('CHAT', l10n.helpOvChatTitle, l10n.helpOvChatSub,
                  l10n.helpOvChatBody),
              card('BOARD', l10n.helpOvBoardTitle, l10n.helpOvBoardSub,
                  l10n.helpOvBoardBody),
              card('OPS', l10n.helpOvOpsTitle, l10n.helpOvOpsSub,
                  l10n.helpOvOpsBody),
            ]),
            HelpTableBlock(
              headers: [
                l10n.helpTblConcept,
                l10n.helpTblDo,
                l10n.helpTblMeaning,
              ],
              rows: [
                [l10n.helpOvRow1A, l10n.helpOvRow1B, l10n.helpOvRow1C],
                [l10n.helpOvRow2A, l10n.helpOvRow2B, l10n.helpOvRow2C],
                [l10n.helpOvRow3A, l10n.helpOvRow3B, l10n.helpOvRow3C],
                [l10n.helpOvRow4A, l10n.helpOvRow4B, l10n.helpOvRow4C],
              ],
            ),
          ],
        ),
        HelpSection(
          label: l10n.helpSecChatLabel,
          title: l10n.helpSecChatTitle,
          icon: Icons.forum_outlined,
          intro: l10n.helpSecChatIntro,
          blocks: [
            HelpTableBlock(
              headers: [
                l10n.helpTblAction,
                l10n.helpTblHow,
                l10n.helpTblEffect,
              ],
              rows: [
                [
                  l10n.helpChatRow1A,
                  '`${l10n.helpChatMentionSyntax}`',
                  l10n.helpChatRow1C,
                ],
                [
                  l10n.helpChatRow2A,
                  '`${l10n.helpChatCardSyntax}`',
                  l10n.helpChatRow2C,
                ],
                [
                  l10n.helpChatRow3A,
                  '`@agents` `@humans` `@all`',
                  l10n.helpChatRow3C,
                ],
                [l10n.helpChatRow4A, l10n.helpChatRow4B, l10n.helpChatRow4C],
                [l10n.helpChatRow5A, l10n.helpChatRow5B, l10n.helpChatRow5C],
              ],
            ),
            HelpCalloutBlock(l10n.helpChat3, tone: HelpCalloutTone.warn),
            HelpCardsBlock([
              card('PRIVATE', l10n.helpChatCardPrivateTitle,
                  l10n.helpChatCardPrivateSub, l10n.helpChat6),
              card('PIN', l10n.helpChatCardPinTitle, l10n.helpChatCardPinSub,
                  l10n.helpChat7),
              card('FOLLOW', l10n.helpChatCardFollowTitle,
                  l10n.helpChatCardFollowSub, l10n.helpChatCardFollowBody),
              card('ARCHIVE', l10n.helpChatCardArchiveTitle,
                  l10n.helpChatCardArchiveSub, l10n.helpChatCardArchiveBody),
            ]),
            HelpCalloutBlock(l10n.helpChat10, tone: HelpCalloutTone.warn),
            HelpItemsBlock([
              HelpItem([HelpChunk.text(l10n.helpChat8)]),
              HelpItem([HelpChunk.text(l10n.helpChat9)]),
              HelpItem([
                HelpChunk.bold(l10n.helpChatStyleLead),
                HelpChunk.text(l10n.helpChatStyle),
              ]),
            ]),
          ],
        ),
        HelpSection(
          label: l10n.helpSecMemberLabel,
          title: l10n.helpSecMemberTitle,
          icon: Icons.group_outlined,
          intro: l10n.helpSecMemberIntro,
          blocks: [
            HelpTableBlock(
              headers: [
                l10n.helpTblState,
                l10n.helpTblSee,
                l10n.helpTblHandle,
              ],
              rows: [
                [
                  l10n.helpMemberRow1A,
                  l10n.helpMemberRow1B,
                  l10n.helpMemberRow1C,
                ],
                [
                  l10n.helpMemberRow2A,
                  l10n.helpMemberRow2B,
                  l10n.helpMemberRow2C,
                ],
                [
                  l10n.helpMemberRow3A,
                  l10n.helpMemberRow3B,
                  l10n.helpMemberRow3C,
                ],
                [
                  l10n.helpMemberRow4A,
                  l10n.helpMemberRow4B,
                  l10n.helpMemberRow4C,
                ],
              ],
            ),
          ],
        ),
        HelpSection(
          label: l10n.helpSecBoardLabel,
          title: l10n.helpSecBoardTitle,
          icon: Icons.dashboard_outlined,
          intro: l10n.helpBoard2,
          blocks: [
            HelpCardsBlock([
              card('01', l10n.helpBoardCardCycleTitle,
                  l10n.helpBoardCardCycleSub, l10n.helpBoardCardCycleBody),
              card('02', l10n.helpBoardCardStageTitle,
                  l10n.helpBoardCardStageSub, l10n.helpBoardCardStageBody),
              card('03', l10n.helpBoardCardTaskTitle,
                  l10n.helpBoardCardTaskSub, l10n.helpBoardCardTaskBody),
            ]),
            HelpTableBlock(
              headers: [
                l10n.helpTblAction,
                l10n.helpTblHow,
                l10n.helpTblEffect,
              ],
              rows: [
                [
                  l10n.helpBoardMoveRow1A,
                  l10n.helpBoardMoveRow1B,
                  l10n.helpBoardMoveRow1C,
                ],
                [
                  l10n.helpBoardMoveRow2A,
                  l10n.helpBoardMoveRow2B,
                  l10n.helpBoardMoveRow2C,
                ],
                [
                  l10n.helpBoardMoveRow3A,
                  l10n.helpBoardMoveRow3B,
                  l10n.helpBoardMoveRow3C,
                ],
                [
                  l10n.helpBoardMoveRow4A,
                  l10n.helpBoardMoveRow4B,
                  l10n.helpBoardMoveRow4C,
                ],
                [
                  l10n.helpBoardMoveRow5A,
                  l10n.helpBoardMoveRow5B,
                  l10n.helpBoardMoveRow5C,
                ],
              ],
            ),
            HelpCalloutBlock(l10n.helpBoardFrozenCallout,
                tone: HelpCalloutTone.warn),
            HelpCalloutBlock(l10n.helpBoardNarrowCallout),
            HelpItemsBlock([
              HelpItem([HelpChunk.text(l10n.helpBoard1)]),
              HelpItem([
                HelpChunk.text(l10n.helpBoard4a),
                const HelpChunk.code('SCRATCHPAD'),
                HelpChunk.text(l10n.helpBoard4b),
              ]),
              HelpItem([HelpChunk.text(l10n.helpBoard5)]),
              HelpItem([
                HelpChunk.bold(l10n.helpBoardOwnerLead),
                HelpChunk.text(l10n.helpBoardOwner),
              ]),
              HelpItem([
                HelpChunk.bold(l10n.helpBoardSupLead),
                HelpChunk.text(l10n.helpBoardSup1),
              ]),
              HelpItem([
                HelpChunk.bold(l10n.helpBoardSupDispatchLead),
                HelpChunk.text(l10n.helpBoardSup2),
              ]),
              HelpItem([
                HelpChunk.bold(l10n.helpBoardSupQuotaLead),
                HelpChunk.text(l10n.helpBoardSup3),
              ]),
              HelpItem([
                HelpChunk.bold(l10n.helpBoardDirectiveLead),
                HelpChunk.text(l10n.helpBoardDirective),
              ]),
            ]),
          ],
        ),
        HelpSection(
          label: l10n.helpSecAssetLabel,
          title: l10n.helpSecAssetTitle,
          icon: Icons.attachment_outlined,
          intro: l10n.helpAsset1,
          blocks: [
            HelpStepsBlock([
              HelpStepData(
                  title: l10n.helpAssetStep1, body: l10n.helpAsset2),
              HelpStepData(
                  title: l10n.helpAssetStep2, body: l10n.helpAsset3),
              HelpStepData(
                  title: l10n.helpAssetStep3, body: l10n.helpAsset4),
              HelpStepData(
                  title: l10n.helpAssetStep4, body: l10n.helpAsset5),
              HelpStepData(
                  title: l10n.helpAssetStep5, body: l10n.helpAsset6),
              HelpStepData(
                  title: l10n.helpAssetStep6, body: l10n.helpAsset7),
            ]),
            HelpCalloutBlock(l10n.helpAsset8),
          ],
        ),
        HelpSection(
          label: l10n.helpSecOpsLabel,
          title: l10n.helpSecOpsTitle,
          icon: Icons.play_circle_outline,
          intro: l10n.helpSecOpsIntro,
          blocks: [
            HelpStepsBlock([
              HelpStepData(
                  title: l10n.helpOpsStep1, body: l10n.helpOpsStep1Body),
              HelpStepData(
                  title: l10n.helpOpsStep2, body: l10n.helpOpsStep2Body),
              HelpStepData(
                  title: l10n.helpOpsStep3, body: l10n.helpOpsStep3Body),
              HelpStepData(
                  title: l10n.helpOpsStep4, body: l10n.helpOpsStep4Body),
            ]),
            HelpTableBlock(
              headers: [
                l10n.helpTblTemplate,
                l10n.helpTblWhat,
                l10n.helpTblDeliver,
              ],
              rows: [
                [
                  l10n.helpOpsTplRow1A,
                  l10n.helpOpsTplRow1B,
                  l10n.helpOpsTplRow1C,
                ],
                [
                  l10n.helpOpsTplRow2A,
                  l10n.helpOpsTplRow2B,
                  l10n.helpOpsTplRow2C,
                ],
                [
                  l10n.helpOpsTplRow3A,
                  l10n.helpOpsTplRow3B,
                  l10n.helpOpsTplRow3C,
                ],
                [
                  l10n.helpOpsTplRow4A,
                  l10n.helpOpsTplRow4B,
                  l10n.helpOpsTplRow4C,
                ],
              ],
            ),
            HelpCalloutBlock(l10n.helpOpsAllReposCallout,
                tone: HelpCalloutTone.warn),
            HelpParagraphBlock(l10n.helpOpsSyncIntro),
            HelpTableBlock(
              headers: [l10n.helpTblSituation, l10n.helpTblRunnerDoes],
              rows: [
                [l10n.helpOpsSyncRow1A, l10n.helpOpsSyncRow1B],
                [l10n.helpOpsSyncRow2A, l10n.helpOpsSyncRow2B],
                [l10n.helpOpsSyncRow3A, l10n.helpOpsSyncRow3B],
                [l10n.helpOpsSyncRow4A, l10n.helpOpsSyncRow4B],
              ],
            ),
            HelpTableBlock(
              headers: [l10n.helpTblAction, l10n.helpTblEffect],
              rows: [
                [l10n.helpOpsCtlRow1A, l10n.helpOpsCtlRow1B],
                [l10n.helpOpsLead7, l10n.helpOps7],
                [l10n.helpOpsLead8, l10n.helpOps8],
                [l10n.helpOpsLead9, l10n.helpOps9],
              ],
            ),
            HelpItemsBlock([
              HelpItem([
                HelpChunk.bold(l10n.helpOpsDashboardLead),
                HelpChunk.text(l10n.helpOpsDashboard),
              ]),
              HelpItem([HelpChunk.text(l10n.helpOps10)]),
              HelpItem([HelpChunk.text(l10n.helpOps11)]),
            ]),
          ],
        ),
        HelpSection(
          label: l10n.helpSecReleaseLabel,
          title: l10n.helpSecReleaseTitle,
          icon: Icons.rocket_launch_outlined,
          intro: l10n.helpSecReleaseIntro,
          blocks: [
            HelpStepsBlock([
              HelpStepData(
                  title: l10n.helpReleaseStep1,
                  body: l10n.helpReleaseStep1Body),
              HelpStepData(
                  title: l10n.helpReleaseStep2,
                  body: l10n.helpReleaseStep2Body),
              HelpStepData(
                  title: l10n.helpReleaseStep3,
                  body: l10n.helpReleaseStep3Body),
            ]),
            HelpParagraphBlock(l10n.helpReleaseFixIntro),
            HelpTableBlock(
              headers: [l10n.helpTblSituation, l10n.helpTblRunnerDoes],
              rows: [
                [l10n.helpReleaseRow1A, l10n.helpReleaseRow1B],
                [l10n.helpReleaseRow2A, l10n.helpReleaseRow2B],
                [l10n.helpReleaseRow3A, l10n.helpReleaseRow3B],
                [l10n.helpReleaseRow4A, l10n.helpReleaseRow4B],
              ],
            ),
            HelpCalloutBlock(l10n.helpReleaseWho, tone: HelpCalloutTone.warn),
            HelpCalloutBlock(l10n.helpReleaseSign),
          ],
        ),
        HelpSection(
          label: l10n.helpSecNotifyLabel,
          title: l10n.helpSecNotifyTitle,
          icon: Icons.notifications_outlined,
          intro: l10n.helpSecNotifyIntro,
          blocks: [
            HelpTableBlock(
              headers: [
                l10n.helpTblEntry,
                l10n.helpTblReceives,
                l10n.helpTblTips,
              ],
              rows: [
                [
                  l10n.helpNotifyRow1A,
                  l10n.helpNotifyRow1B,
                  l10n.helpNotifyRow1C,
                ],
                [
                  l10n.helpNotifyRow2A,
                  l10n.helpNotifyRow2B,
                  l10n.helpNotifyRow2C,
                ],
                [
                  l10n.helpNotifyRow3A,
                  l10n.helpNotifyRow3B,
                  l10n.helpNotifyRow3C,
                ],
              ],
            ),
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
          blocks: [
            HelpStepsBlock([
              HelpStepData(title: l10n.helpConnStep1, body: l10n.helpConn1),
              HelpStepData(
                  title: l10n.helpConnStep2, body: l10n.helpConnStep2Body),
              HelpStepData(
                  title: l10n.helpConnStep3, body: l10n.helpConnStep3Body),
            ]),
            HelpItemsBlock([
              HelpItem([
                HelpChunk.text(l10n.helpConn2a),
                const HelpChunk.code('http://127.0.0.1:8787'),
                HelpChunk.text(l10n.helpConn2b),
                const HelpChunk.code('0.0.0.0'),
                HelpChunk.text(l10n.helpConn2c),
              ]),
              HelpItem([HelpChunk.text(l10n.helpConn5)]),
            ]),
          ],
        ),
        HelpSection(
          label: l10n.helpSecInviteLabel,
          title: l10n.helpSecInviteTitle,
          icon: Icons.vpn_key_outlined,
          intro: l10n.helpInvite1,
          blocks: [
            HelpCardsBlock([
              card('HUMAN', l10n.helpInviteCardHumanTitle,
                  l10n.helpInviteCardHumanSub, l10n.helpInviteCardHumanBody),
              card('AGENT', l10n.helpInviteCardAgentTitle,
                  l10n.helpInviteCardAgentSub, l10n.helpInviteCardAgentBody),
              card('CODE', l10n.helpInviteCardCodeTitle,
                  l10n.helpInviteCardCodeSub, l10n.helpInviteCardCodeBody),
            ]),
            HelpTableBlock(
              headers: [l10n.helpTblAction, l10n.helpTblEffect],
              rows: [
                [l10n.helpInviteRow1A, l10n.helpInviteRow1B],
                [l10n.helpInviteRow2A, l10n.helpInviteRow2B],
                [l10n.helpInviteRow3A, l10n.helpInviteRow3B],
                [l10n.helpInviteRow4A, l10n.helpInviteRow4B],
              ],
            ),
          ],
        ),
        HelpSection(
          label: l10n.settingsTabVisual,
          title: l10n.settingsTabVisual,
          icon: Icons.palette_outlined,
          blocks: [
            HelpTableBlock(
              headers: [
                l10n.helpTblSetting,
                l10n.helpTblOption,
                l10n.helpTblNote,
              ],
              rows: [
                [
                  l10n.helpVisualRow1A,
                  l10n.helpVisualRow1B,
                  l10n.helpVisualRow1C,
                ],
                [
                  l10n.helpVisualRow2A,
                  l10n.helpVisualRow2B,
                  l10n.helpVisualRow2C,
                ],
                [
                  l10n.helpVisualRow3A,
                  l10n.helpVisualRow3B,
                  l10n.helpVisualRow3C,
                ],
              ],
            ),
            HelpCalloutBlock(l10n.helpVisual3),
          ],
        ),
        HelpSection(
          label: l10n.settingsTabPersonal,
          title: l10n.settingsTabPersonal,
          icon: Icons.person_outline,
          blocks: [
            HelpTableBlock(
              headers: [l10n.helpTblSetting, l10n.helpTblNote],
              rows: [
                [l10n.helpPersonalRow1A, l10n.helpPersonal1],
                [l10n.helpPersonalRow2A, l10n.helpPersonal2],
                [l10n.helpPersonalRow3A, l10n.helpPersonal3],
                [l10n.helpPersonalRow4A, l10n.helpPersonal4],
                [l10n.helpPersonalRow5A, l10n.helpPersonalRow5B],
              ],
            ),
          ],
        ),
        HelpSection(
          label: l10n.helpSecVersionLabel,
          title: l10n.helpSecVersionTitle,
          icon: Icons.verified_outlined,
          blocks: [
            HelpCalloutBlock(l10n.helpVersionUpdate),
            HelpItemsBlock([
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
            ]),
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
          intro: l10n.helpMachine1,
          blocks: [
            HelpTableBlock(
              headers: [l10n.helpTblTab, l10n.helpTblShows],
              rows: [
                [l10n.helpMachineTabRow1A, l10n.helpMachineTabRow1B],
                [l10n.helpMachineTabRow2A, l10n.helpMachineTabRow2B],
                [l10n.helpMachineTabRow3A, l10n.helpMachineTabRow3B],
              ],
            ),
            HelpCalloutBlock(l10n.helpMachine2),
            HelpCalloutBlock(l10n.helpMachine3, tone: HelpCalloutTone.warn),
            HelpParagraphBlock(l10n.helpMachine4),
            HelpTableBlock(
              headers: [
                l10n.helpTblToken,
                l10n.helpTblCan,
                l10n.helpTblGiveTo,
              ],
              rows: [
                [
                  l10n.helpMachineTokenRow1A,
                  l10n.helpMachineTokenRow1B,
                  l10n.helpMachineTokenRow1C,
                ],
                [
                  l10n.helpMachineTokenRow2A,
                  l10n.helpMachineTokenRow2B,
                  l10n.helpMachineTokenRow2C,
                ],
              ],
            ),
            HelpCalloutBlock(l10n.helpMachineTokenWarn,
                tone: HelpCalloutTone.warn),
            HelpItemsBlock(
              [
                HelpItem([
                  HelpChunk.text(l10n.helpMachine6a),
                  const HelpChunk.code('0.0.0.0'),
                  HelpChunk.text(l10n.helpMachine6b),
                ]),
                HelpItem([HelpChunk.text(l10n.helpMachine7)]),
                HelpItem([HelpChunk.text(l10n.helpMachine8)]),
                HelpItem([HelpChunk.text(l10n.helpMachine9)]),
                HelpItem([
                  HelpChunk.bold(l10n.helpInstallLead),
                  HelpChunk.text(l10n.helpInstall1),
                ]),
                HelpItem([
                  HelpChunk.bold(l10n.helpInstallReleaseLead),
                  HelpChunk.text(l10n.helpInstall2),
                ]),
                HelpItem([
                  HelpChunk.bold(l10n.helpInstallBlockedLead),
                  HelpChunk.text(l10n.helpInstall3),
                ]),
                HelpItem([
                  HelpChunk.bold(l10n.helpInstallHubLead),
                  HelpChunk.text(l10n.helpInstall4),
                ]),
                HelpItem([
                  HelpChunk.bold(l10n.helpInstallConfigLead),
                  HelpChunk.text(l10n.helpInstall5),
                ]),
                HelpItem([
                  HelpChunk.bold(l10n.helpEnvLead),
                  HelpChunk.text(l10n.helpEnv1),
                ]),
              ],
              groups: {4: l10n.helpGroupInstall},
            ),
          ],
        ),
        HelpSection(
          label: l10n.helpSecTunnelLabel,
          title: l10n.helpSecTunnelTitle,
          icon: Icons.cloud_outlined,
          blocks: [
            HelpCalloutBlock(l10n.helpTunnel1, tone: HelpCalloutTone.warn),
            HelpItemsBlock([
              HelpItem([HelpChunk.text(l10n.helpTunnel2)]),
              HelpItem([
                HelpChunk.text(l10n.helpTunnel3a),
                const HelpChunk.code('attachments/'),
                HelpChunk.text(l10n.helpTunnel3b),
                const HelpChunk.code('backups\\'),
                HelpChunk.text(l10n.helpTunnel3c),
              ]),
              HelpItem([HelpChunk.text(l10n.helpTunnel4)]),
            ]),
          ],
        ),
        HelpSection(
          label: l10n.helpSecLinkLabel,
          title: l10n.helpSecLinkTitle,
          icon: Icons.smart_toy_outlined,
          intro: l10n.helpLink1,
          blocks: [
            HelpCalloutBlock(l10n.helpLink2),
            HelpItemsBlock([
              HelpItem([
                HelpChunk.text(l10n.helpLink3a),
                const HelpChunk.code('chatroom_join'),
                HelpChunk.text(l10n.helpLink3b),
                const HelpChunk.code('bridge.commit'),
                HelpChunk.text(l10n.helpLink3c),
              ]),
            ]),
          ],
        ),
        HelpSection(
          label: l10n.helpSecRunnerLabel,
          title: l10n.helpSecRunnerTitle,
          icon: Icons.terminal,
          intro: l10n.helpRunner1,
          blocks: [
            HelpCalloutBlock(l10n.helpRunnerLoginCallout),
            HelpItemsBlock([
              HelpItem([
                HelpChunk.bold(l10n.helpRunnerWorkspaceLead),
                HelpChunk.text(l10n.helpRunnerWorkspace),
              ]),
              HelpItem([
                HelpChunk.bold(l10n.helpRunnerSkillLead),
                HelpChunk.text(l10n.helpRunnerSkill),
              ]),
              HelpItem([
                HelpChunk.text(l10n.helpRunner2a),
                const HelpChunk.code(
                    '%LOCALAPPDATA%\\UEP\\Chatroom\\runner\\config.json'),
                HelpChunk.text(l10n.helpRunner2b),
                const HelpChunk.code('runner/config.example.json'),
                HelpChunk.text(l10n.helpRunner2c),
              ]),
            ]),
            HelpTableBlock(
              headers: [l10n.helpTblKey, l10n.helpTblPurpose],
              rows: [
                ['`workspaces`', l10n.helpRunnerRow1],
                ['`projects`', l10n.helpRunnerRow2],
                ['`allowed_branches`', l10n.helpRunnerRow3],
                ['`default_project`', l10n.helpRunnerRow4],
                ['`stable_branch`', l10n.helpRunnerRow5],
                ['`release`', l10n.helpRunnerRow6],
                ['`agent_signing_key`', l10n.helpRunnerRow7],
                ['`login_check_seconds`', l10n.helpRunnerRow8],
                ['`context_window_tokens`', l10n.helpRunnerRow9],
                ['`allowed_mcp_servers`', l10n.helpRunnerRow10],
              ],
            ),
            HelpCalloutBlock(l10n.helpRunner8, tone: HelpCalloutTone.warn),
          ],
        ),
        HelpSection(
          label: l10n.helpSecVersionLabel,
          title: l10n.helpSecVersionTitle,
          icon: Icons.verified_outlined,
          blocks: [
            HelpItemsBlock([
              HelpItem([HelpChunk.text(l10n.helpVersionHub1)]),
            ]),
          ],
        ),
      ],
    ),
  };
}

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
          // 不能用 ListView：它只建視窗附近的子項，導覽點到還沒建出來的節
          // 時 key.currentContext 是 null，點了就靜默不動。說明文件是固定的
          // 靜態內容，整份建出來的成本可忽略，換來任何捲動位置都捲得到。
          final content = SingleChildScrollView(
            padding: const EdgeInsets.all(32),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
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
                  _SectionView(
                    key: _sectionKeys[i],
                    section: doc.sections[i],
                  ),
                  if (i != doc.sections.length - 1) const SizedBox(height: 36),
                ],
              ],
            ),
          );
          if (!wide) return content;
          return Center(
            child: ConstrainedBox(
              constraints:
                  const BoxConstraints(maxWidth: kHelpContentMaxWidth + 200),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 200,
                    child: _NavColumn(doc: doc, onTap: _jumpTo),
                  ),
                  Expanded(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(
                          maxWidth: kHelpContentMaxWidth),
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
              key: ValueKey('help-nav-$i'),
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
            key: ValueKey('help-nav-$i'),
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
                Flexible(
                  child: Text(doc.sections[i].title,
                      style: UepText.sans(size: 13.5, color: s.inkSoft)),
                ),
              ]),
            ),
          ),
      ],
    );
  }
}

/// 一節：標題＋導語＋依序排下去的區塊。
class _SectionView extends StatelessWidget {
  const _SectionView({super.key, required this.section});

  final HelpSection section;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return HelpSectionBlock(
      title: section.title,
      // 小標中文化後有幾節的 label 與標題同字，重複列出只是雜訊
      label: section.label != section.title ? section.label : null,
      icon: section.icon,
      intro: section.intro,
      children: [
        for (final block in section.blocks) _buildBlock(context, l10n, block),
      ],
    );
  }

  Widget _buildBlock(
      BuildContext context, AppLocalizations l10n, HelpBlock block) {
    switch (block) {
      case HelpItemsBlock():
        return _ItemsView(block: block);
      case HelpCardsBlock():
        return HelpCardGrid(cards: block.cards);
      case HelpTableBlock():
        return HelpTable(headers: block.headers, rows: block.rows);
      case HelpCalloutBlock():
        return HelpCallout(
          text: block.text,
          tone: block.tone,
          title: block.tone == HelpCalloutTone.warn
              ? l10n.helpCalloutWarn
              : l10n.helpCalloutTip,
        );
      case HelpStepsBlock():
        return HelpSteps(steps: block.steps);
      case HelpParagraphBlock():
        return HelpRichText(block.text);
    }
  }
}

class _ItemsView extends StatelessWidget {
  const _ItemsView({required this.block});

  final HelpItemsBlock block;

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < block.items.length; i++) ...[
          if (block.groups.containsKey(i))
            Padding(
              padding: EdgeInsets.only(top: i == 0 ? 0 : 8, bottom: 6),
              child: MonoLabel(block.groups[i]!,
                  color: s.inkMute.withValues(alpha: .7)),
            ),
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: _ItemRow(item: block.items[i]),
          ),
        ],
      ],
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
    // 首個 chunk 是粗體 ⇒ 它自己一行當小標，剩下的接在下面。
    final lead = item.hasLead ? item.chunks.first : null;
    final rest = lead == null ? item.chunks : item.chunks.sublist(1);
    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (lead != null)
          Text(lead.text,
              style: body.copyWith(fontWeight: FontWeight.w700, height: 1.5)),
        if (rest.isNotEmpty)
          Text.rich(helpChunksSpan(rest), style: body),
      ],
    );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 5),
          child: Container(width: 10, height: 1, color: s.lineStrong),
        ),
        const SizedBox(width: 10),
        Expanded(child: text),
      ],
    );
  }
}
