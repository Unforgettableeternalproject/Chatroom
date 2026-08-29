import 'package:flutter/material.dart';

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
  });

  final List<Attachment> attachments;
  final String serverUrl;
  final String token;

  Map<String, String> get _headers =>
      token.isEmpty ? const {} : {'Authorization': 'Bearer $token'};

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
              child: a.isImage
                  ? _ImageAttachment(
                      attachment: a, url: _url(a), headers: _headers)
                  : _FileAttachment(attachment: a),
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
