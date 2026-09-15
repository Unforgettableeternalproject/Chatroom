import 'dart:typed_data';
import 'dart:ui' as ui;

/// PNG 的 magic bytes：89 50 4E 47 0D 0A 1A 0A。
const _pngMagic = <int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];

/// 這串 bytes 是不是真的 PNG。
bool looksLikePng(Uint8List bytes) {
  if (bytes.length < _pngMagic.length) return false;
  for (var i = 0; i < _pngMagic.length; i++) {
    if (bytes[i] != _pngMagic[i]) return false;
  }
  return true;
}

/// 把剪貼簿來的圖轉成**真正的 PNG**。已經是 PNG 就原樣回傳。
///
/// 為什麼需要這個：Windows 剪貼簿的原生圖片格式是 DIB（BMP），
/// `Pasteboard.image` 在該平台回的就是 BMP bytes。把它命名成 `.png`、
/// mime 標成 `image/png` 送上去，會產生一個**只有 App 自己讀得懂的檔案**：
/// Skia 認得 BMP 所以 App 顯示正常，看起來一切都好；但 agent 端的檔案讀取
/// 工具靠 magic bytes 判型，一律拒收，而錯誤訊息看起來像「檔案壞了」。
/// 也就是說每一張貼上的截圖 agent 都看不到，人類卻完全察覺不到這件事
/// （2026-08-30 實測，1.4 MB 的截圖）。
///
/// 順帶一提體積：同一張圖 BMP 1.4 MB、PNG 約十分之一。
///
/// 解碼失敗時回傳原 bytes——貼上一張看不懂的東西不該讓輸入框壞掉，
/// 維持現狀至少不比修之前差。
Future<Uint8List> toPngBytes(Uint8List bytes) async {
  if (looksLikePng(bytes)) return bytes;
  try {
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    final data = await frame.image.toByteData(format: ui.ImageByteFormat.png);
    frame.image.dispose();
    codec.dispose();
    if (data == null) return bytes;
    return data.buffer.asUint8List();
  } catch (_) {
    return bytes;
  }
}
