# Flutter 開發環境安裝紀錄（P3-01）

> 安裝日期：2026-08-27
> 目標機器：Windows 11 Pro 25H2（build 10.0.26200.9168），locale zh-TW
> 對應卡片：`docs/TASKS.md` P3-01
> 本文件記錄**實際做過的事**，不是通用教學。重灌或換機時照本文重跑即可。

## 0. 結論摘要

| 項目 | 值 |
|------|------|
| Flutter 版本 | **3.47.1**（stable channel） |
| Dart SDK | 3.13.1 |
| DevTools | 2.60.0 |
| Framework revision | `6655482ec0`（2026-08-19） |
| Engine revision | `5d53178869` |
| 安裝路徑 | `C:\Users\Bernie\dev\flutter` |
| 安裝方式 | 官方 zip 解壓（非 winget、非 git clone） |
| PATH 設定 | HKCU registry `Environment\Path`（**非 setx**，理由見 §2） |
| Windows desktop | ✅ 可建置（已實測 release build 產出 exe） |
| Android | ❌ 未安裝，刻意的（見 §4） |
| 需要管理員權限 | **無**。全程未提權、未動系統 PATH、未安裝 Visual Studio |

---

## 1. 安裝方式與選擇理由

採用**官方 zip 解壓到使用者層級路徑**：

```
下載：https://storage.googleapis.com/flutter_infra_release/releases/stable/windows/flutter_windows_3.47.1-stable.zip
解壓：C:\Users\Bernie\dev\flutter
```

版本與 URL 來自官方 release manifest
`https://storage.googleapis.com/flutter_infra_release/releases/releases_windows.json`
的 `current_release.stable`。

### 為什麼不用 winget

`winget install --id=Google.Flutter` 會裝到 winget 的 Packages 目錄，
版本綁在 winget manifest 的更新節奏上，而**Flutter 自己的升級機制是 `flutter upgrade`**
（它會直接改動 SDK 目錄）。兩套升級機制疊在同一份 SDK 上，
之後只要有人跑過 `flutter upgrade`，winget 眼中的版本就對不上實際版本，
`winget upgrade` 反而可能把 SDK 蓋回舊版。SDK 由 Flutter 自己管，職責才單一。

### 為什麼不用 `git clone -b stable`

git clone 的 SDK 是一個**活的 git 工作區**，狀態取決於當下 `git pull` 到哪個 commit，
不是一個可指名的版本。zip 有官方 SHA256，能驗、能重現、能在文件裡寫死一個確切版本號——
這對「可重現的建置」是必要的。已驗證下載檔的 SHA256 與 manifest 完全相符：

```
4cbf94fde1f5f8d6b9fc50b2483b57cf2077f61712282c2f4cf92560168f442b
```

### 為什麼是 `%USERPROFILE%\dev\flutter` 而不是 `C:\flutter` 或 Program Files

- `C:\Program Files\` 底下寫入需要 UAC，而且 Flutter 執行時**會寫回自己的 SDK 目錄**
  （`bin/cache/`、`version` 檔、pub 快取索引），裝在需要提權的位置日後每次
  `flutter upgrade` / `flutter precache` 都會踩權限問題。
- 路徑不含空白字元，避開 Flutter 工具鏈在 Windows 上對含空白路徑的歷史性雷。
- 使用者層級路徑不需要管理員權限，符合本次任務「不提權」的前提。

> ⚠️ **SDK 路徑不得寫死進任何專案程式碼或設定檔**（P3-01 驗收條件 4）。
> 一律靠 PATH 上的 `flutter` 解析。CI 上路徑會完全不同。

---

## 2. PATH 設定方式（有坑，請讀）

`C:\Users\Bernie\dev\flutter\bin` 已加入**使用者層級** PATH。系統 PATH 未被更動。

**這裡沒有用 `setx`，有兩個各自獨立的致命理由：**

### 坑 1：setx 的 1024 字元截斷

`setx` 會把超過 1024 字元的值**直接截斷**（只給一行警告就照做）。
本機 HKCU 的 PATH 原始長度是 **1633 字元**，遠超上限——
用 setx 會靜默砍掉一半以上的 PATH 條目，災難級。

### 坑 2：值的型別是 `REG_EXPAND_SZ`，不能退化成 `REG_SZ`

本機 PATH 內含未展開的變數參照：

```
%PNPM_HOME%
%USERPROFILE%\AppData\Local\Microsoft\WindowsApps
%USERPROFILE%\.dotnet\tools
%NVM_HOME%
%NVM_SYMLINK%
```

這些能運作，是因為 registry 值的型別是 `REG_EXPAND_SZ`（`ExpandString`）。
`[Environment]::SetEnvironmentVariable(..., 'User')` 寫入時會把型別變成 `REG_SZ`，
那一刻起 `%NVM_HOME%` 等就**永遠不會被展開**，nvm / pnpm / dotnet tools 全部失效
——而且症狀是「某天突然找不到 node」，極難聯想回這次改動。

### 實際採用的做法

直接開 registry 寫入，並以 `GetValueKind()` 取回原型別、原樣寫回：

```powershell
$k = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
$raw  = $k.GetValue('Path', $null,
        [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)  # 關鍵：不展開
$kind = $k.GetValueKind('Path')                                              # ExpandString
$k.SetValue('Path', $raw.TrimEnd(';') + ';C:\Users\Bernie\dev\flutter\bin', $kind)
$k.Close()
```

`DoNotExpandEnvironmentNames` 同樣是關鍵——少了它，讀出來的就是已展開的字面路徑，
寫回去等於把所有變數參照固化成當下的值。

寫入後廣播 `WM_SETTINGCHANGE`（`SendMessageTimeout(HWND_BROADCAST, 0x1A, ..., "Environment")`），
讓**新開的** shell 不必登出就吃得到。已開著的 shell 仍需自行重開。

- 變更後長度：1664 字元
- 型別：`ExpandString`（已驗證維持不變）
- 原始值備份於 scratchpad `HKCU-Path-backup.txt`（暫存性質，勿依賴）

### 👉 生效範圍：需要重開終端機

已驗證 registry 值正確、`flutter.bat` 與 `dart.bat` 都在
`C:\Users\Bernie\dev\flutter\bin` 解析得到。

但**設定當下已經開著的所有進程仍是舊 PATH**——包括正在跑的終端機、
VS Code、以及 Claude Code 本身。這些進程在啟動時就把父進程的環境變數複製走了，
`WM_SETTINGCHANGE` 只影響**之後才啟動**的進程。

所以：**首次使用前請重開終端機 / VS Code**（不需要登出或重開機）。
如果 `flutter` 指令回報「不是內部或外部命令」，先確認是不是這個原因，
不要急著懷疑安裝失敗。

---

## 3. `flutter doctor` 輸出摘要

```
[√] Flutter (Channel stable, 3.47.1, on Microsoft Windows [10.0.26200.9168], locale zh-TW)
[√] Windows Version (Windows 11 or higher, 25H2, 2009)
[X] Android toolchain - develop for Android devices
    X Unable to locate Android SDK.
[√] Chrome - develop for the web
[√] Visual Studio - develop Windows apps (Visual Studio Build Tools 2022 17.14.16)
[√] Connected device (3 available)  — Windows (desktop) / Chrome (web) / Edge (web)
[√] Network resources
```

**目標平台（Windows desktop）無任何 ✗，符合 P3-01 驗收條件 1。**

### 關於 Visual Studio：本機不需要任何安裝動作

這台機器同時裝了兩份 VS 2022（皆為既有安裝，本次未動）：

| 安裝 | 路徑 | C++ 工作負載 |
|------|------|------|
| VS Community 2022 17.14.16 | `C:\Program Files\Microsoft Visual Studio\2022\Community` | ❌ 未註冊 `VC.Tools.x86.x64` |
| **VS Build Tools 2022 17.14.16** | `C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools` | ✅ 完整 |

Flutter 挑中的是 **Build Tools**，不是 Community。已逐項確認 Build Tools 具備：

- `Microsoft.VisualStudio.Workload.VCTools`（C++ 建置工具工作負載）
- `Microsoft.VisualStudio.Component.VC.Tools.x86.x64`（MSVC 編譯器 14.44.35207）
- `Microsoft.VisualStudio.Component.VC.CMake.Project`（Flutter 依賴 VS 內附的 CMake）
- Windows SDK 10.0.19041 / 11 SDK 22621 / 26100（Flutter 選用 10.0.26100.0）

> 因此**不需要開 Visual Studio Installer、不需要 UAC**。
> 若未來換機且 doctor 對 Visual Studio 報 ✗，需要補的精確項目就是上列四項；
> 用 VS Installer 勾「使用 C++ 的桌面開發」（Desktop development with C++）工作負載即可涵蓋，
> 這個動作需要管理員權限。

### 查詢工作負載的方法（換機時直接照用）

```powershell
$vsw = 'C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe'
& $vsw -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
```

無輸出＝該元件不存在。注意 `-products *` 不可省略，
否則 vswhere 預設**不會列出 Build Tools**（它不是 IDE 產品），會誤判成「沒有 C++ 工具鏈」。

---

## 4. Android toolchain：刻意不裝

`flutter doctor` 的 `[X] Android toolchain` 是**已知且可接受**的狀態，不是待修問題。

- 本階段（P3-02 起）只在 Windows desktop 上開發與驗證
- Android SDK + Android Studio 體積龐大，且會引入 JDK / licence 接受等額外流程
- 真正要上手機時再處理；屆時 `flutter doctor --android-licenses` 也要一併跑過

在那之前，**任何人看到這個 ✗ 都不需要動作**。

---

## 5. 驗證結果

於**暫存目錄**（非專案內）`C:\Users\Bernie\dev\_smoke\smoke_app` 建立樣板專案驗證，
驗證後已刪除。

| 步驟 | 結果 |
|------|------|
| `flutter create smoke_app` | ✅ Wrote 131 files |
| `flutter analyze` | ✅ `No issues found!`（5.0s） |
| `flutter build windows --release` | ✅ `Built build\windows\x64\runner\Release\smoke_app.exe`（28.3s） |

產物：`smoke_app.exe`（90 KB）+ `flutter_windows.dll`（21 MB）+ `data\`。

> 未實際啟動該 exe（依專案規範不主動啟動程式）。
> 完整的 `flutter run` 於 P3-02 建立正式專案時再做。

### ⚠️ 過程中踩到的坑：MAX_PATH（很重要，一定會再遇到）

第一次驗證在一個**很長的暫存路徑**下進行，`flutter build windows` 失敗：

```
CMake Error at CMakeLists.txt:3 (project):
  No CMAKE_CXX_COMPILER could be found.
```

**這個錯誤訊息會騙人。** 它看起來像「C++ 工具鏈沒裝」，
於是很容易被誤判成要去裝 Visual Studio（需要 UAC、下載數 GB）——完全是白工。

翻 `build\windows\x64\CMakeFiles\CMakeConfigureLog.yaml` 才看到真相：

- `CL.exe` **有被找到、也成功編譯了** `CMakeCXXCompilerId.cpp`
- 真正倒下的是 Link 階段：`FileTracker : error FTK1011`，
  MSBuild 無法建立 `.tlog` 追蹤檔，因為完整路徑超過 **MAX_PATH（260 字元）**

CMake 只看到「compiler id 測試專案 build 失敗」，就回報成
「找不到編譯器」。**症狀與根因差了十萬八千里。**

換到短路徑 `C:\Users\Bernie\dev\_smoke` 後，同一份 SDK、同一套工具鏈，
一次就建置成功。

#### 已確認：`LongPathsEnabled` 救不了這個

本機 `HKLM\SYSTEM\CurrentControlSet\Control\FileSystem\LongPathsEnabled` **已經是 1**，
但建置仍然失敗。原因是 MSBuild 的 **FileTracker 走的是舊式 Win32 API**，
不理會這個開關。**不要以為開了長路徑支援就沒事了。**

#### 給後續開發的規則

1. **專案的 build 目錄路徑要短。** Flutter 的 Windows build 會在
   `build\windows\x64\...` 底下疊出很深的 CMake / MSBuild 中繼路徑，
   光是中繼結構本身就吃掉 100+ 字元，留給專案根路徑的預算很有限。
2. 專案目前位於
   `C:\Users\Bernie\source\repos\Unforgettableeternalproject\Chatroom`（65 字元），
   加上 `app\`（P3-02）後仍在安全範圍，**但餘裕不算多**。
   若日後 Windows build 出現任何 `FTK1011` 或詭異的
   `No CMAKE_CXX_COMPILER`，**第一個要懷疑的就是路徑長度，不是工具鏈**。
3. 排除的方法：把專案 clone 到短路徑（如 `C:\src\chatroom`）重試一次。
   一分鐘就能證實或排除，比裝 Visual Studio 便宜太多。
4. CI 上尤其要注意——runner 的工作目錄路徑往往比本機更長。

---

## 6. 未來升級注意事項

### 升級指令

```powershell
flutter upgrade          # 跟隨 stable channel 升到最新
flutter --version        # 升級後務必記錄新版本號並更新本文件 §0 表格
```

### 升級前務必注意

1. **升級是就地改動 `C:\Users\Bernie\dev\flutter`**，沒有自動備份。
   大版本升級（如 3.47 → 3.5x）建議先把整個 SDK 目錄複製一份，
   或直接保留舊 zip，rollback 時解壓到另一個目錄再改 PATH 即可。
2. **rollback 方式**：Flutter 沒有 `downgrade` 到任意版本的可靠指令
   （`flutter downgrade` 只回到上一個「用過」的版本）。
   可靠做法是從 release manifest 找到目標版本的 zip 重裝，
   所以**舊版 zip 的 URL 值得記在 commit message 或本文件裡**。
3. **升級後一律重跑 `flutter doctor -v` 與一次 `flutter build windows`**。
   Flutter 每個版本都可能提高對 MSVC / Windows SDK 的最低要求，
   而本機的 C++ 工具鏈是既有安裝、不在我們控制之下，
   一旦最低要求被拉高，就會變成需要 UAC 的 VS Installer 動作。
4. **升級後跑 `flutter clean` 再 build**。跨版本的 `build/` 殘留是
   「本機好好的、換台機器就爆」這類問題的常見來源。
5. **不要為了修某個套件而切到 beta/master channel**。
   本專案釘死 stable；真的需要，開另一份 SDK 目錄切 PATH，不要污染這一份。

### 版本一致性

- 專案的 `pubspec.yaml` 應宣告 `environment: sdk:` 下限，讓 Dart 版本不一致時**早點爆**，
  而不是在建置到一半時報奇怪的錯（由 P3-02 建立專案時落地）。
- 若日後接 CI，CI 上的 Flutter 版本**必須明確釘住** 3.47.1（例如
  `subosito/flutter-action` 的 `flutter-version`），
  不可用 `stable` 浮動標籤——否則上游一發版，CI 就跟本機分岔。

### 磁碟空間

SDK 目錄目前實測 **3.04 GB**（已含 Windows desktop 的 artifacts），
`bin/cache/` 會隨著使用的目標平台持續長大
（加了 Android 之後還會更多）。`flutter clean` 只清專案的 `build/`，不清 SDK 快取。
真的要瘦身用 `flutter precache --help` 挑平台，別手動刪 `bin/cache/`。

---

## 7. 本次過程中未發生／未做的事

- 未安裝或修改任何 Visual Studio 元件
- 未更動系統層級（HKLM）環境變數
- 未安裝 Android SDK / Android Studio / JDK
- 未在專案目錄內建立任何驗證用檔案（樣板專案在暫存目錄）
- 未執行任何需要 UAC 提權的動作
