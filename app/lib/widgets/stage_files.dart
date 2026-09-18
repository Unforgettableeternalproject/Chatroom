import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/errors/api_exception.dart';
import '../core/theme/uep_theme.dart';
import '../core/theme/uep_tokens.dart';
import '../models/board.dart';
import '../models/stage_file.dart';
import '../state/app_providers.dart';
import '../state/board_providers.dart';
import '../state/composer_attachments.dart';
import '../state/messages_providers.dart';
import 'attachment_view.dart';
import 'uep_button.dart';

/// 階段素材（共享附件）的畫面元件。
///
/// 素材掛在**階段**上，該階段底下的卡與 run 共用——所以它的入口在階段標題
/// 列，不在某一張卡裡面。契約見階段素材契約（2026-09-17）。

/// 把素材相關的失敗講成使用者看得懂的一句話。
///
/// ⚠️ **判準是 code 與型別，不是 message 的字串比對**（api_exception 的規矩）。
/// 兩個特例值得寫死：重複掛不是錯誤而是「它已經在上面了」，403 則要講「沒有
/// 權限」而不是 Hub 那句與房間身分有關的話——素材的權限來自板與掛接房，
/// 重新加入聊天室一百次也不會改變它。
String stageFileErrorText(ApiException e) {
  if (e.code == 'stage_file_exists') return '這份素材已經在階段上';
  if (e is BoardAccessException ||
      e is ParticipantInvalidException ||
      e is RootTokenRequiredException ||
      e is HumanCredentialRequiredException ||
      e is NotYourAgentException) {
    return '沒有權限';
  }
  return e.message;
}

/// 素材動作共用的執行殼。回 `null` 代表失敗，且已經對使用者說過了。
Future<T?> runStageFileAction<T>(
  BuildContext context,
  Future<T> Function() body,
) async {
  try {
    return await body();
  } on ApiException catch (e) {
    if (!context.mounted) return null;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(stageFileErrorText(e))));
    return null;
  }
}

/// 階段標題列上的素材數。**0 不顯示**——沒有素材是常態，
/// 每一列都掛一個「素材 0」只會讓真的有東西的那幾列不顯眼。
class StageFileCount extends StatelessWidget {
  const StageFileCount({super.key, required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    if (count <= 0) return const SizedBox.shrink();
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(Icons.attach_file, size: 12, color: s.inkMute),
      const SizedBox(width: 3),
      Text('素材 $count',
          style:
              UepText.mono(size: 10, color: s.inkMute, letterSpacing: 1.4)),
    ]);
  }
}

/// 依 mime 給一個圖示。**只是讓人一眼分得出哪一列是圖、哪一列是報告**，
/// 認不出來的型別就用通用檔案圖示，不要為了精準去猜副檔名。
IconData stageFileIcon(String mime) {
  if (mime.startsWith('image/')) return Icons.image_outlined;
  if (mime == 'application/pdf') return Icons.picture_as_pdf_outlined;
  if (mime.startsWith('video/')) return Icons.movie_outlined;
  if (mime.startsWith('audio/')) return Icons.audiotrack_outlined;
  if (mime.startsWith('text/')) return Icons.description_outlined;
  if (mime.contains('zip') || mime.contains('compressed')) {
    return Icons.folder_zip_outlined;
  }
  return Icons.insert_drive_file_outlined;
}

/// 展開之後的素材清單。每列一份素材，點檔名開檢視（圖片在 App 內，其餘
/// 交給系統程式），右邊一顆卸除。
class StageFilesList extends ConsumerWidget {
  const StageFilesList({
    super.key,
    required this.boardId,
    required this.checklistId,
    required this.files,
    required this.actions,
    this.participantId,
    this.readOnly = false,
    this.onAdd,
  });

  /// 這塊板。**還不知道時（房軸要等第一次回應）呼叫端不要畫這個元件**。
  final String boardId;
  final String checklistId;
  final List<StageFile> files;

  /// 卸除要打 API。唯讀或還沒有身分時是 null。
  final BoardActions? actions;

  /// 房內身分。附件是房內內容，取圖要它——沒有時圖片畫佔位而不是發出
  /// 一個註定 401 的請求（同 [AttachmentView] 的理由）。
  final String? participantId;
  final bool readOnly;

  /// 「新增素材」。唯讀或沒有房（附件要上傳到某一間房）時是 null，那時
  /// 空清單整個不佔版面。
  final VoidCallback? onAdd;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (files.isEmpty && onAdd == null) return const SizedBox.shrink();
    final config = ref.watch(appConfigProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final f in files)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: _StageFileRow(
              file: f,
              serverUrl: config.serverUrl,
              token: config.token,
              participantId: participantId,
              onRemove: (readOnly || actions == null)
                  ? null
                  : () => _remove(context, f),
            ),
          ),
        // 入口留在清單底部：要加東西的人是先看過已經有什麼才決定加的。
        // 空清單不放空狀態文案——那句話佔的位置比這顆按鈕還大
        if (onAdd != null)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: TextButton.icon(
              onPressed: onAdd,
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              icon: Icon(Icons.add, size: 14, color: context.uep.inkMute),
              label: Text('新增素材',
                  style: UepText.fieldLabel(color: context.uep.inkMute)),
            ),
          ),
      ],
    );
  }

  Future<void> _remove(BuildContext context, StageFile f) async {
    // 卸除確認一次：素材是別人可能正在用的東西，而清單上每一列長得一樣，
    // 按錯一格與按對一格在畫面上沒有差別
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('卸除素材',
                style: UepText.sectionTitle(color: context.uep.inkTitle)),
            const SizedBox(height: 4),
            // 檔名放在標題底下：確認的那句話要短，但按錯一列的人需要看得到
            // 自己按的是哪一份
            Text(f.filename,
                style: UepText.mono(size: 10.5, color: context.uep.inkMute)),
          ],
        ),
        content: Text(
          '移除這份素材？',
          style: UepText.serif(
              size: 14, color: context.uep.inkSoft, height: 1.8),
        ),
        actions: [
          UepButton(
            label: '取消',
            variant: UepButtonVariant.outline,
            onPressed: () => Navigator.of(context).pop(false),
          ),
          UepButton(
              label: '卸除', onPressed: () => Navigator.of(context).pop(true)),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    await runStageFileAction(
      context,
      () => actions!.removeStageFile(boardId, checklistId, f.id),
    );
  }
}

class _StageFileRow extends ConsumerWidget {
  const _StageFileRow({
    required this.file,
    required this.serverUrl,
    required this.token,
    required this.participantId,
    required this.onRemove,
  });

  final StageFile file;
  final String serverUrl;
  final String token;
  final String? participantId;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.uep;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Icon(stageFileIcon(file.mime), size: 15, color: s.inkMute),
            const SizedBox(width: 8),
            // 檔名就是開啟的入口：檢視與下載整組沿用訊息附件那份
            // （[openAttachmentPreview]）——素材與附件在使用者眼裡是同一種
            // 東西，兩套實作會長出兩種行為
            Flexible(
              child: InkWell(
                onTap: () => openAttachmentPreview(
                  context,
                  ref,
                  attachment: file.asAttachment,
                  serverUrl: serverUrl,
                  token: token,
                  participantId: participantId,
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Text(
                    file.filename,
                    style: UepText.serif(size: 13.5, color: s.ink, height: 1.5),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Text(file.readableSize,
                style: UepText.mono(
                    size: 10, color: s.inkMute, letterSpacing: 1.1)),
            if (file.addedByName.isNotEmpty) ...[
              const SizedBox(width: 8),
              Text('· ${file.addedByName} 掛上',
                  style: UepText.mono(size: 10, color: s.inkMute)),
            ],
            if (onRemove != null)
              IconButton(
                tooltip: '從階段卸除',
                visualDensity: VisualDensity.compact,
                onPressed: onRemove,
                icon: Icon(Icons.link_off, size: 15, color: s.inkMute),
              ),
          ],
        ),
        // note 是「這份素材是什麼」。沒有的話這一行整個不出現——空白的
        // 一行會讓清單看起來每一列都少了東西
        if (file.note.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(left: 23, top: 1),
            child: Text(file.note,
                style: UepText.serif(size: 13, color: s.inkSoft, height: 1.6)),
          ),
      ],
    );
  }
}

/// 階段列的「加素材」：選檔 → 上傳到目前這間房 → 掛上階段。
///
/// 🔴 **要有房才做得到**：附件是房內資源（`POST /api/rooms/{rid}/attachments`），
/// 而 Board Library 那條路徑上連上傳到哪間房都答不出來。呼叫端在沒有房時
/// 不要畫這顆按鈕。
Future<void> pickAndAttachStageFile(
  BuildContext context,
  WidgetRef ref, {
  required String boardId,
  required String checklistId,
  required String roomId,
  required BoardActions actions,
}) async {
  // file_picker 12 起 pickFiles 是靜態方法，取消時回空 list 而不是 null，
  // 而且預設就是多選——選了三個檔案，這裡就要問三次、掛三次
  final picked = await FilePicker.pickFiles();
  if (picked.isEmpty || !context.mounted) return;

  // 逐檔序列處理，不是只吃第一個：一次選多個檔案時，前面那份少掉的不是
  // 上傳失敗，是後面的檔案從來沒被問過、也從來沒被送出去過
  for (final file in picked) {
    final path = file.path;
    if (path == null) continue;
    if (!context.mounted) return;

    final note = await showStageNoteDialog(context, filename: file.name);
    // 對某一份素材按了取消，就當成整批都反悔了——不是使用者自己選要
    // 略過這一份，繼續問下一份只會讓人以為剛剛那次取消沒有生效
    if (note == null || !context.mounted) return;

    // 這一份失敗（重複、沒權限……）[runStageFileAction] 已經說過話了，
    // 不能讓它擋住還沒問過的其餘檔案——選了五個檔案，其中一個已經掛過，
    // 不該讓剩下四個因此連問都沒問到
    await runStageFileAction(context, () async {
      final identity = await ref.read(identityProvider(roomId).future);
      final uploaded = await ref.read(attachmentsApiProvider).uploadPath(
            roomId,
            participantId: identity.participantId,
            path: path,
            filename: file.name,
            mime: ComposerAttachmentDrafts.guessMime(file.name),
          );
      return actions.addStageFile(
        boardId,
        checklistId,
        attachmentId: uploaded.id,
        note: note,
      );
    });
  }
}

/// 問一句「這份素材是什麼」。**可以留白**——逼人寫一句話才掛得上去，
/// 結果會是一堆「圖」「log」，那比空的還糟。
///
/// 回 `null` 代表取消，回空字串代表留白。
Future<String?> showStageNoteDialog(
  BuildContext context, {
  required String filename,
  String? stageTitle,
}) {
  final controller = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (dialogContext) {
      final s = dialogContext.uep;
      void submit() =>
          Navigator.of(dialogContext).pop(controller.text.trim());
      return AlertDialog(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('加素材', style: UepText.pageTitle(color: s.inkTitle)),
            const SizedBox(height: 4),
            Text(stageTitle == null ? filename : '$filename › $stageTitle',
                style: UepText.mono(size: 10.5, color: s.inkMute)),
          ],
        ),
        content: SizedBox(
          width: 420,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('這是什麼（可留白）',
                  style: UepText.fieldLabel(color: s.inkSoft)),
              const SizedBox(height: 7),
              Container(
                decoration: BoxDecoration(
                  color: s.bgSunken,
                  border: Border.all(color: s.hairlineStrong),
                  borderRadius: BorderRadius.circular(8),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: TextField(
                  controller: controller,
                  autofocus: true,
                  onSubmitted: (_) => submit(),
                  style: UepText.serif(size: 14, color: s.ink, height: 1.6),
                  decoration: InputDecoration(
                    isDense: true,
                    border: InputBorder.none,
                    hintText: '說明（選填）',
                    hintStyle: UepText.serif(size: 13, color: s.inkMute),
                    contentPadding:
                        const EdgeInsets.symmetric(vertical: 12),
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          UepButton(
            label: '取消',
            variant: UepButtonVariant.outline,
            onPressed: () => Navigator.of(dialogContext).pop(),
          ),
          UepButton(label: '掛上', onPressed: submit),
        ],
      );
    },
  );
}

/// 訊息附件的「加到階段」：挑這間房掛著的板底下**還開著的**階段。
///
/// 收尾／取消的階段不列出來——掛上去也不會有人看到它，而那時使用者已經
/// 以為交代完了。
Future<void> showAddToStageDialog(
  BuildContext context,
  WidgetRef ref, {
  required String roomId,
  required String attachmentId,
  required String filename,
}) async {
  final snapshot = ref.read(boardProvider(roomId)).value;
  final boardId = ref.read(boardCacheProvider.notifier).boardIdOf(roomId);
  final stages = <(BoardObjective, BoardChecklist)>[
    if (snapshot != null)
      for (final o in snapshot.sortedObjectives)
        for (final c in snapshot.checklistsOf(o.id))
          if (c.status == 'open' && !c.isUncategorised) (o, c),
  ];

  if (snapshot == null || boardId == null || stages.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('這間房的板上還沒有開著的階段')),
    );
    return;
  }

  final picked = await showDialog<BoardChecklist>(
    context: context,
    builder: (dialogContext) {
      final s = dialogContext.uep;
      return AlertDialog(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('加到階段',
                style: UepText.pageTitle(color: s.inkTitle)),
            const SizedBox(height: 4),
            Text(filename, style: UepText.mono(size: 10.5, color: s.inkMute)),
          ],
        ),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final (o, c) in stages)
                  InkWell(
                    onTap: () => Navigator.of(dialogContext).pop(c),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 9),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(c.title,
                              style: UepText.sans(
                                  size: 14,
                                  weight: FontWeight.w600,
                                  color: s.ink)),
                          // 階段名字在不同週期底下會重複（「測試」「收尾」），
                          // 只列階段的話挑的人分不出是哪一個
                          Text(o.title,
                              style:
                                  UepText.mono(size: 10.5, color: s.inkMute)),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          UepButton(
            label: '取消',
            variant: UepButtonVariant.outline,
            onPressed: () => Navigator.of(dialogContext).pop(),
          ),
        ],
      );
    },
  );
  if (picked == null || !context.mounted) return;

  final note = await showStageNoteDialog(context,
      filename: filename, stageTitle: picked.title);
  if (note == null || !context.mounted) return;

  // 失敗時 [runStageFileAction] 已經說過話了，回 null——**那時不可以再報
  // 一次成功**，兩句話會同時停在畫面上，而後說的那句是錯的
  final added = await runStageFileAction(
    context,
    () => ref.read(boardActionsProvider(roomId)).addStageFile(
          boardId,
          picked.id,
          attachmentId: attachmentId,
          note: note,
        ),
  );
  if (added == null || !context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text('已掛到階段：${picked.title}')),
  );
}
