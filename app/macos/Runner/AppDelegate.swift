import Cocoa
import FlutterMacOS
import window_manager

@main
class AppDelegate: FlutterAppDelegate {
  // closeToTray 開著（window_manager 的 preventClose 已裝）時，紅燈只是把
  // 視窗藏起來，此時「沒有可見視窗」不能讓 App 結束；沒裝攔截時維持原行為，
  // 關掉最後一個視窗就結束。Cmd+Q 與匣選單的「結束」走 NSApp.terminate，
  // 不受這個回傳值影響。
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    for window in NSApp.windows {
      if let manager = window.delegate as? WindowManager, manager.isPreventClose() {
        return false
      }
    }
    return true
  }

  // closeToTray 開著時，紅燈只是把視窗藏起來（window_manager 的 preventClose
  // ＋ hide）。點 Dock 圖示要能把它叫回來，否則使用者只剩 Cmd+Q 一條路。
  override func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    if !flag {
      for window in NSApp.windows {
        if !window.isVisible {
          window.setIsVisible(true)
        }
        window.makeKeyAndOrderFront(self)
        NSApp.activate(ignoringOtherApps: true)
      }
    }
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
