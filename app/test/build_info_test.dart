import 'package:chatroom_app/core/config/build_info.dart';
import 'package:flutter_test/flutter_test.dart';

BuildInfo _app(String commit) =>
    BuildInfo(version: '1.0.0', commit: commit, builtAt: '');

void main() {
  group('版本識別', () {
    test('取不到 commit 時明說未知，不退回版本號', () {
      // 「不知道自己是哪一版」與「是 1.0.0 版」是完全不同的兩件事，
      // 把前者顯示成後者正是這次事故的成因
      final unknown = _app('');
      expect(unknown.isKnown, isFalse);
      expect(unknown.label, contains('未知'));
      expect(unknown.label, isNot('1.0.0'));
    });

    test('有 commit 時帶進標籤——那才是「哪一份程式碼」', () {
      expect(_app('47ac574abc12').label, '1.0.0+47ac574abc12');
    });

    test('dirty 產物對不回任何一個 commit，要看得出來', () {
      expect(_app('47ac574-dirty').isDirty, isTrue);
      expect(_app('47ac574').isDirty, isFalse);
    });
  });

  group('與 Hub 對帳', () {
    test('同一顆 commit → same', () {
      expect(
        BuildInfo.compare(_app('47ac574abc12'), {'commit': '47ac574abc12'}),
        VersionMatch.same,
      );
    });

    test('短 hash 長度不同仍算同一顆——兩邊的產生方式不一樣', () {
      // App 由 build 指令帶入、Hub 用 rev-parse --short=12；要求等長的話
      // 同一顆 commit 會被判成不符，然後每次啟動都跳一個假警示
      expect(
        BuildInfo.compare(_app('47ac574'), {'commit': '47ac574abc12'}),
        VersionMatch.same,
      );
      expect(
        BuildInfo.compare(_app('47ac574abc12'), {'commit': '47ac574'}),
        VersionMatch.same,
      );
    });

    test('不同 commit → different', () {
      expect(
        BuildInfo.compare(_app('47ac574'), {'commit': 'e0287e9'}),
        VersionMatch.different,
      );
    });

    test('App 講不出自己是哪一份 → unknown，不是 same', () {
      // 把「無法比對」顯示成「相符」等於把這整套機制關掉，而且關得無聲無息
      expect(
        BuildInfo.compare(_app(''), {'commit': '47ac574'}),
        VersionMatch.unknown,
      );
    });

    test('Hub 講不出自己是哪一份 → unknown，不是 same', () {
      expect(
        BuildInfo.compare(_app('47ac574'), {'commit': ''}),
        VersionMatch.unknown,
      );
      expect(BuildInfo.compare(_app('47ac574'), null), VersionMatch.unknown);
    });

    test('兩邊都不知道 → unknown（最該警示的情況，絕不能是 same）', () {
      expect(BuildInfo.compare(_app(''), {'commit': ''}), VersionMatch.unknown);
    });
  });
}
