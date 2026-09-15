import 'dart:typed_data';

import 'package:chatroom_app/core/util/image_bytes.dart';
import 'package:flutter_test/flutter_test.dart';

/// 貼上的圖必須是**真的** PNG。
///
/// Windows 剪貼簿給的是 BMP，而 App 用 Skia 顯示、看得懂 BMP，所以人類端
/// 完全察覺不到問題；agent 端靠 magic bytes 判型，一律拒收。這組測試守的
/// 是「送出去的東西與它自稱的格式一致」。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 最小的 2x2 24-bit BMP：跟 Windows 剪貼簿給的是同一族格式。
  Uint8List tinyBmp() {
    const w = 2, h = 2;
    const rowSize = 8; // 2 px × 3 bytes = 6 → 補齊到 4 的倍數 = 8
    const pixelBytes = rowSize * h;
    const fileSize = 54 + pixelBytes;
    final b = BytesBuilder();
    b.add([0x42, 0x4D]); // "BM"
    b.add(Uint8List(4)..buffer.asByteData().setUint32(0, fileSize, Endian.little));
    b.add(Uint8List(4)); // 保留
    b.add(Uint8List(4)..buffer.asByteData().setUint32(0, 54, Endian.little));
    // DIB header（BITMAPINFOHEADER，40 bytes）
    final dib = ByteData(40);
    dib.setUint32(0, 40, Endian.little);
    dib.setInt32(4, w, Endian.little);
    dib.setInt32(8, h, Endian.little);
    dib.setUint16(12, 1, Endian.little); // planes
    dib.setUint16(14, 24, Endian.little); // bpp
    dib.setUint32(20, pixelBytes, Endian.little);
    b.add(dib.buffer.asUint8List());
    // 像素資料（BGR，每列補齊到 4 bytes）
    b.add([0xFF, 0x00, 0x00, 0x00, 0xFF, 0x00, 0, 0]);
    b.add([0x00, 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0, 0]);
    return b.toBytes();
  }

  test('BMP 不會被誤認成 PNG', () {
    expect(looksLikePng(tinyBmp()), isFalse);
  });

  test('BMP 會被轉成真正的 PNG', () async {
    final png = await toPngBytes(tinyBmp());
    expect(looksLikePng(png), isTrue,
        reason: '送出去的東西必須與它自稱的 image/png 一致');
  });

  test('已經是 PNG 就原封不動，不重新編碼一次', () async {
    final png = await toPngBytes(tinyBmp());
    final again = await toPngBytes(png);
    expect(identical(again, png), isTrue);
  });

  test('看不懂的資料原樣回傳，不讓貼上動作壞掉', () async {
    final junk = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8, 9]);
    final out = await toPngBytes(junk);
    expect(out, junk);
  });
}
