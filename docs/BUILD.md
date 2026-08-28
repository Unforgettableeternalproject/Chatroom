# UI 建置步驟（P3-10）

## 前置

- Flutter 3.47.1 stable @ `C:\Users\Bernie\dev\flutter`（見 SETUP-FLUTTER.md）
- **Windows 開發人員模式必須開啟**：plugin 建置需要 symlink 支援。
  `start ms-settings:developers` → 開發人員模式 → 開。
  未開啟時 `flutter build windows` 會直接以
  「Building with plugins requires symlink support」中止。
- ⚠️ 路徑長度：出現 `FTK1011` 或莫名的 `No CMAKE_CXX_COMPILER` 時，
  先懷疑 MAX_PATH（見 SETUP-FLUTTER.md），不是工具鏈。

## Windows desktop（主要目標）

```powershell
cd app
C:\Users\Bernie\dev\flutter\bin\flutter.bat build windows --release
```

產物：`app\build\windows\x64\runner\Release\`——**整個資料夾**就是可攜的
發行單位（chatroom_app.exe + flutter_windows.dll + data\）。
複製到未安裝 Flutter 的機器即可執行（需要 VC++ Redistributable 2015+，
一般機器都有）。

開發期間直接跑：

```powershell
cd app
C:\Users\Bernie\dev\flutter\bin\flutter.bat run -d windows
```

## Android（次要，本機未裝 toolchain）

Android SDK 刻意未安裝（P3-01 決策）。要出 APK 時：

1. 安裝 Android Studio 或 cmdline-tools + platform-tools + build-tools
2. `flutter doctor --android-licenses`
3. `flutter build apk --release`

## 驗證

- `flutter analyze` → 0 issues
- `flutter test` → 全綠（目前 26 項）
- 手動測試走 `docs/UI-TEST-CHECKLIST.md`

## 字型注意

字型走 google_fonts 執行期下載（Cormorant Garamond / Noto Serif TC /
Inter / JetBrains Mono），首次啟動需網路，之後有本機快取。
若要完全離線，把字型檔放進 `app/assets/fonts/` 並改用 pubspec 宣告
（`lib/core/theme/uep_theme.dart` 是唯一接觸點）。
