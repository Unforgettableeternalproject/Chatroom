# Chatroom v1.2.9

v1.2.9：App、Hub、執行器與三包 kit 支援 macOS 與 Linux。內容涵蓋 v1.2.8-hotfix2 之後的所有變更。資料庫沒有變更。

## 新增

- **macOS App**：資產 `chatroom-app-<tag>-macos-universal.zip`，同時支援 Apple Silicon 與 Intel。
  - 關閉視窗縮到選單列，點 Dock 或選單列圖示叫回視窗。
  - 登入 token 存在鑰匙圈。
- **Linux App**：資產 `chatroom-app-<tag>-linux-x64.tar.gz`，解壓即可執行，執行檔為 `chatroom`。
  - 需要桌面環境提供系統匣（StatusNotifier）才能縮到匣；沒有時設定裡的開關會停用，關閉視窗直接結束。
- **kit 支援 macOS／Linux**：Hub、執行器與 bridge 三包 kit 新增 `install.sh`。
  - 服務改由 launchd（macOS）或 systemd user unit（Linux）管理，以 `scripts/service.py` 操作。
  - 安裝位置：macOS `~/Library/Application Support/UEP/Chatroom`；Linux `${XDG_DATA_HOME:-~/.local/share}/uep/chatroom`。
- **App 內的主機控制台、執行器服務、自我更新**在 macOS 與 Linux 上都能使用。
- **執行器登入終端機**：macOS 用「終端機」，Linux 依序嘗試常見的終端機程式。

## 修正

- **Windows PowerShell 5.1 無法執行執行器安裝腳本**：`install-task.ps1` 等腳本改為帶 BOM 的 UTF-8。
- **執行器預設主機名稱**：改用系統主機名稱，不再讀 `COMPUTERNAME`。

## 升級注意

- **Linux 版的 App 沒有在 Linux 系統上實際測試過**：只在 WSL 模擬的環境中測過，不保證功能可以正常運作。
- **macOS 版沒有經過 Apple 公證**：從瀏覽器下載後第一次開啟會被擋下，請在 Finder 對 App 按右鍵 >「打開」，或執行 `xattr -dr com.apple.quarantine Chatroom.app`。
- **Linux 版在 Ubuntu 24.04 建置**：比 24.04 舊的發行版可能無法執行；系統需要有 GTK 3、libayatana-appindicator3、libsecret，以及中文字型（例如 `fonts-noto-cjk`），否則標題與標籤的中文會顯示成方塊。
- **macOS 與 Linux 的自我更新要到下一版才會第一次用到**：若「檢查更新」失敗，請到 Releases 頁面手動下載新版。
- Windows 的行為沒有變更。
- v1.2.5 起的 App 可以用「檢查更新」直接更新。
