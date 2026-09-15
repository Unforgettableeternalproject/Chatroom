import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/errors/api_exception.dart';
import '../state/app_providers.dart';

import '../core/theme/uep_theme.dart';
import '../core/theme/uep_tokens.dart';
import '../models/attachment.dart';

/// 訊息底下的附件區。
///
/// 圖片直接內嵌顯示——附件的用途多半是「這個你看一下」，要人再點一下才看得到
/// 就失去意義了。非圖片顯示成一列檔案資訊。
class AttachmentView extends StatelessWidget {
  const AttachmentView({
    super.key,
    required this.attachments,
    required this.serverUrl,
    required this.token,
    this.participantId,
  });

  final List<Attachment> attachments;
  final String serverUrl;
  final String token;

  /// 房內身分。房間是讀取邊界，附件跟著訊息走——非成員取不到。
  /// 舊版 Hub 忽略這個標頭，帶了不影響。
  ///
  /// **還沒拿到身分時不要去抓圖。** 身分是 join 完成之後才有的，而訊息
  /// 可能在那之前就畫出來了。那個空窗期裡發出的請求會被 Hub 以 401 擋下，
  /// 而 Flutter 的 NetworkImage **相等性只看 url 與 scale、不含 headers**
  /// ——同一個 url 的失敗結果會被沿用，身分到齊之後也不會自己重試。
  /// 使用者看到的就是「永遠只有檔名」。（2026-08-29 實機發現）
  final String? participantId;

  /// Hub 現在要求房內身分才給附件。沒有身分時連請求都不要發出去。
  bool get _canFetch =>
      participantId != null && participantId!.isNotEmpty;

  Map<String, String> get _headers => {
        if (token.isNotEmpty) 'Authorization': 'Bearer $token',
        if (participantId != null && participantId!.isNotEmpty)
          'X-Participant-Id': participantId!,
      };

  String _url(Attachment a) => '$serverUrl/api/attachments/${a.id}';

  @override
  Widget build(BuildContext context) {
    if (attachments.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final a in attachments)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: a.isImage
                        ? (_canFetch
                            ? _ImageAttachment(
                                attachment: a, url: _url(a), headers: _headers)
                            // 身分還沒到：畫佔位而不是發註定失敗的請求
                            : _ImagePlaceholder(attachment: a))
                        : _FileAttachment(attachment: a),
                  ),
                  // 存檔鈕獨立於預覽之外：蓋在圖片上會擋住內容，而附件的
                  // 用途多半就是「這個你看一下」
                  DownloadAttachmentButton(
                      attachment: a, participantId: participantId),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _ImageAttachment extends StatelessWidget {
  const _ImageAttachment({
    required this.attachment,
    required this.url,
    required this.headers,
  });

  final Attachment attachment;
  final String url;
  final Map<String, String> headers;

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    return GestureDetector(
      onTap: () => showDialog<void>(
        context: context,
        builder: (_) => _FullScreenImage(
            url: url, headers: headers, filename: attachment.filename),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: ConstrainedBox(
          // 不限高的話一張長截圖會把整個時間軸推走
          constraints: const BoxConstraints(maxHeight: 320, maxWidth: 480),
          child: Image.network(
            url,
            headers: headers,
            fit: BoxFit.contain,
            loadingBuilder: (context, child, progress) => progress == null
                ? child
                : Container(
                    width: 240,
                    height: 120,
                    color: s.bgSunken,
                    alignment: Alignment.center,
                    child: const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: UepColors.gold),
                    ),
                  ),
            // 載入失敗要看得出是哪一張、以及它還在不在——Hub 的資料庫與附件
            // 目錄可能不同步（只備份了 db），那時圖片會永久取不回來
            errorBuilder: (context, error, stack) => _FileAttachment(
              attachment: attachment,
              note: '圖片載入失敗',
            ),
          ),
        ),
      ),
    );
  }
}

/// 把附件存到本機。
///
/// 走系統存檔對話框（`file_picker` 已是既有依賴），由使用者決定放哪裡——
/// 自動丟到「下載」資料夾會讓人找不到，而這個 App 的附件常常是要拿去
/// 別的地方用的（截圖、log、報告）。
class DownloadAttachmentButton extends ConsumerStatefulWidget {
  const DownloadAttachmentButton({
    super.key,
    required this.attachment,
    required this.participantId,
  });

  final Attachment attachment;
  final String? participantId;

  @override
  ConsumerState<DownloadAttachmentButton> createState() =>
      _DownloadAttachmentButtonState();
}

class _DownloadAttachmentButtonState
    extends ConsumerState<DownloadAttachmentButton> {
  bool _busy = false;

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _save() async {
    final pid = widget.participantId;
    if (pid == null || pid.isEmpty) {
      // 房間是讀取邊界，沒有身分連請求都不該發
      _toast('還在取得房間身分，稍候再試');
      return;
    }
    setState(() => _busy = true);
    try {
      final bytes = await ref
          .read(attachmentsApiProvider)
          .download(widget.attachment.id, participantId: pid);
      // 先下載再開對話框：對話框開著時如果下載才失敗，使用者已經選好位置
      // 卻拿到一個錯誤，那個順序讓人以為是存檔失敗（其實是取檔失敗）
      final saved = await FilePicker.saveFile(
        fileName: widget.attachment.filename,
        bytes: bytes,
        mimeType: widget.attachment.mime,
        dialogTitle: '儲存附件',
      );
      if (saved == null) return;   // 使用者按了取消，不是錯誤
      _toast('已存檔：${widget.attachment.filename}');
    } on AttachmentGoneException catch (e) {
      // metadata 在、實體不在：講清楚它回不來了，別讓人一直重試
      _toast(e.message);
    } on ApiException catch (e) {
      _toast('下載失敗：${e.message}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    return IconButton(
      tooltip: '存到本機',
      visualDensity: VisualDensity.compact,
      onPressed: _busy ? null : _save,
      icon: _busy
          ? const SizedBox(
              width: 13,
              height: 13,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: UepColors.gold),
            )
          : Icon(Icons.download_outlined, size: 15, color: s.inkMute),
    );
  }
}


/// 身分就緒前的圖片佔位。
///
/// 刻意不是錯誤狀態——這不是失敗，是還沒開始。畫成錯誤會讓人去查一個
/// 不存在的問題，而它通常在幾百毫秒內就自己好了。
class _ImagePlaceholder extends StatelessWidget {
  const _ImagePlaceholder({required this.attachment});

  final Attachment attachment;

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    return Container(
      width: 240,
      height: 120,
      decoration: BoxDecoration(
        color: s.bgSunken,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: s.line),
      ),
      alignment: Alignment.center,
      child: const SizedBox(
        width: 18,
        height: 18,
        child: CircularProgressIndicator(strokeWidth: 2, color: UepColors.gold),
      ),
    );
  }
}


class _FileAttachment extends StatelessWidget {
  const _FileAttachment({required this.attachment, this.note});

  final Attachment attachment;
  final String? note;

  @override
  Widget build(BuildContext context) {
    final s = context.uep;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: s.bgSunken,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: s.line),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(note == null ? Icons.attach_file : Icons.broken_image_outlined,
            size: 15, color: s.inkMute),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            attachment.filename,
            style: UepText.sans(size: 12.5, color: s.ink),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(width: 10),
        Text(
          note ?? attachment.readableSize,
          style: UepText.mono(size: 9.5, color: s.inkMute, letterSpacing: 1.1),
        ),
      ]),
    );
  }
}

class _FullScreenImage extends StatelessWidget {
  const _FullScreenImage({
    required this.url,
    required this.headers,
    required this.filename,
  });

  final String url;
  final Map<String, String> headers;
  final String filename;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(24),
      child: GestureDetector(
        onTap: () => Navigator.of(context).pop(),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Flexible(
            // 截圖常常又長又細，固定縮放看不清楚——給它可縮放可平移
            child: InteractiveViewer(
              maxScale: 5,
              child: Image.network(url, headers: headers, fit: BoxFit.contain),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            filename,
            style: UepText.mono(
                size: 10, color: Colors.white70, letterSpacing: 1.2),
          ),
        ]),
      ),
    );
  }
}
