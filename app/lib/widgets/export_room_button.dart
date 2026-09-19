import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/errors/api_exception.dart';
import '../export/conversation_format.dart';
import '../l10n/l10n.dart';
import '../state/app_providers.dart';
import '../state/rooms_providers.dart';
import 'uep_button.dart';

/// 把整個房間存成一份可讀的對話紀錄。
///
/// **封存房也要能用**——那正是主要用途：房間可以被永久刪除，而那不可逆，
/// 備份是封存之後最需要的動作。所以這顆按鈕不掛在「非封存房才顯示」那組
/// 裡面。
class ExportRoomButton extends ConsumerStatefulWidget {
  const ExportRoomButton({super.key, required this.roomId});

  final String roomId;

  @override
  ConsumerState<ExportRoomButton> createState() => _ExportRoomButtonState();
}

class _ExportRoomButtonState extends ConsumerState<ExportRoomButton> {
  bool _busy = false;

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _export() async {
    final l10n = AppLocalizations.of(context);
    final pid = ref.read(settingsRepoProvider).participantId(widget.roomId);
    if (pid == null) {
      // 匯出要成員身分（Hub 端驗）。這句講清楚是「還沒拿到」而不是「不准」
      _toast(l10n.roomsIdentityPending);
      return;
    }
    setState(() => _busy = true);
    try {
      final messages = await ref
          .read(exportApiProvider)
          .fetchAll(widget.roomId, participantId: pid);
      // 先抓完再開對話框：對話框開著時才失敗的話，使用者已經選好位置卻拿到
      // 一個錯誤，那個順序讓人以為是存檔失敗（其實是取檔失敗）。與附件下載
      // 同一個理由，行為也保持一致
      final text = formatConversationLog(
        roomName: _roomName(),
        messages: messages,
      );
      final saved = await FilePicker.saveFile(
        fileName: _fileName(),
        bytes: utf8.encode(text),
        mimeType: 'text/plain',
        dialogTitle: l10n.roomsExportLog,
      );
      if (saved == null) return; // 按了取消，不是錯誤
      _toast(l10n.roomsExportDone(messages.length));
    } on ApiException catch (e) {
      _toast(l10n.roomsExportFailed(e.message));
    } on FormatException {
      // parseJsonl 在有壞行時整份失敗——那是刻意的，但錯誤要說得出人話
      _toast(l10n.roomsExportParseFailed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 給人看的檔名由 client 命名——Hub 那端一律用 room_id，因為房名是使用者
  /// 輸入，直接進 `Content-Disposition` 就是標頭注入的破口。這裡是本機檔名，
  /// 只要擋掉檔案系統不收的字元就好。
  /// 房名從房間詳情取；還沒載入時退回 room id——那不好看，但比讓匯出等
  /// 一個非必要的請求好。
  String _roomName() =>
      ref.read(roomDetailProvider(widget.roomId)).value?.room.name ??
      widget.roomId;

  String _fileName() {
    final safe = _roomName()
        .replaceAll(RegExp(r'[\/:*?"<>|\r\n]'), '_')
        .trim();
    final base = safe.isEmpty ? widget.roomId : safe;
    final now = DateTime.now();
    final stamp = '${now.year}'
        '${now.month.toString().padLeft(2, '0')}'
        '${now.day.toString().padLeft(2, '0')}';
    return '$base-$stamp.txt';
  }

  @override
  Widget build(BuildContext context) {
    return UepButton(
      label: _busy
          ? AppLocalizations.of(context).roomsExporting
          : AppLocalizations.of(context).roomsExportLog,
      variant: UepButtonVariant.outline,
      small: true,
      expand: true,
      onPressed: _busy ? null : _export,
    );
  }
}
