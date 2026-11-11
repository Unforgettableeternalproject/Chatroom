import 'package:chatroom_app/screens/chat/focus_loader.dart';
import 'package:flutter_test/flutter_test.dart';

/// 捲動自動載入歷史的閘門。
void main() {
  group('shouldAutoLoadOlder', () {
    bool gate({bool loading = false, bool focusing = false}) =>
        shouldAutoLoadOlder(
          loading: loading,
          focusing: focusing,
          hasClients: true,
          pixels: 900,
          maxScrollExtent: 1000,
        );

    test('一般捲到接近頂端照常載入', () => expect(gate(), isTrue));
    test('跳轉期間不載入', () => expect(gate(focusing: true), isFalse));
    test('正在載入就不重複載', () => expect(gate(loading: true), isFalse));
    test(
        '離頂端還遠不載入',
        () => expect(
            shouldAutoLoadOlder(
              loading: false,
              focusing: false,
              hasClients: true,
              pixels: 100,
              maxScrollExtent: 1000,
            ),
            isFalse));
  });
}
