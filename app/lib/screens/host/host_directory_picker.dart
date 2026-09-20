import 'package:file_picker/file_picker.dart';

/// 開系統的資料夾選擇器。取消回 `null`。
///
/// 「這台機器」頁上每一個「瀏覽」都走這一支：各自寫一份的話，某個平台上
/// 沒有選擇器時，有的欄位會炸、有的只是安靜地什麼都不做。
Future<String?> pickHostDirectory(String title) async {
  try {
    final path = await FilePicker.getDirectoryPath(dialogTitle: title);
    if (path == null || path.trim().isEmpty) return null;
    return path;
  } on Object {
    // 沒有選擇器可用的平台：旁邊的輸入框照樣打得了字
    return null;
  }
}
