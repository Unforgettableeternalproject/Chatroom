import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/agent_run.dart';

/// 把 run 的收工回報組成一份可以帶走的 Markdown。
///
/// **組裝與存檔分開**：組裝是純函式（測得到內容），存檔要開系統對話框
/// （測不到，也不該在測試裡真的開）。中間那條線是 [RunReportSaver]。
///
/// **標頭用 Hub 的欄位名**：`kind` / `ref` / `status` 這些是契約上的鍵，
/// 匯出的檔案會被貼進 issue、丟給別的工具讀，翻成當下介面語言反而讓同一
/// 份回報在不同人手上長得不一樣。介面上的字才跟著語言走。

/// run id 的短碼：檔名用得到，整串 32 碼進檔名太長。
String runExportShortId(String id) => id.length <= 8 ? id : id.substring(0, 8);

/// 單筆回報的檔名。
String runReportFileName(AgentRun run) =>
    'chatroom-run-${runExportShortId(run.id)}.md';

/// 「全部匯出」的檔名。日期是給人分辨兩次匯出用的。
String runReportsFileName([DateTime? now]) {
  final d = now ?? DateTime.now();
  final stamp = '${d.year}'
      '${d.month.toString().padLeft(2, '0')}'
      '${d.day.toString().padLeft(2, '0')}';
  return 'chatroom-runs-$stamp.md';
}

/// 一筆回報的 Markdown：標頭（種類、目標、時間、狀態、reason）＋ result 原文。
///
/// result **不重排、不截斷**：它本來就是 Markdown，匯出的意義就是把原文
/// 完整帶走。沒有 result 時退回 reason——失敗的那幾筆只有 reason。
String formatRunReport(AgentRun run) {
  final b = StringBuffer();
  b.writeln('# chatroom run ${runExportShortId(run.id)}');
  b.writeln();
  b.writeln('- kind: ${run.kind}');
  if (run.project.isNotEmpty) b.writeln('- project: ${run.project}');
  if (run.ref.isNotEmpty) b.writeln('- ref: ${run.ref}');
  final agent = run.agentName;
  if (agent != null && agent.isNotEmpty) b.writeln('- agent: $agent');
  b.writeln('- status: ${run.status}');
  final ended = run.endedAt ?? run.updatedAt;
  if (ended.isNotEmpty) b.writeln('- ended_at: $ended');
  if (run.reason.isNotEmpty) b.writeln('- reason: ${run.reason}');
  b.writeln();
  b.writeln('---');
  b.writeln();
  b.write(run.result.isEmpty ? run.reason : run.result);
  return b.toString();
}

/// 目前列出的幾筆合成一份。順序照傳進來的清單（＝畫面上的順序）。
String formatRunReports(List<AgentRun> runs) {
  final b = StringBuffer();
  b.writeln('# chatroom runs (${runs.length})');
  b.writeln();
  for (final run in runs) {
    b.writeln(formatRunReport(run));
    b.writeln();
  }
  return b.toString().trimRight();
}

/// 存檔那一步。回傳存到的路徑，`null` ＝使用者按了取消（不是錯誤）。
typedef RunReportSaver = Future<String?> Function({
  required String fileName,
  required String text,
  required String dialogTitle,
});

/// 預設實作：系統存檔對話框（`file_picker` 已是既有依賴，與附件下載同一條路）。
Future<String?> saveRunReportFile({
  required String fileName,
  required String text,
  required String dialogTitle,
}) async =>
    (await FilePicker.saveFile(
      fileName: fileName,
      bytes: utf8.encode(text),
      mimeType: 'text/markdown',
      dialogTitle: dialogTitle,
    ))
        ?.toString();

/// 測試把這個換掉就不會真的開對話框。
final runReportSaverProvider =
    Provider<RunReportSaver>((ref) => saveRunReportFile);
