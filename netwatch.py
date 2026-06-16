#!/usr/bin/env python3
"""NetWatch - macOS menu bar 網路斷線提醒工具.

第一版 (1.0.0): 顯示 menu bar 圖示與選單。
網路偵測與音效會在後續 chunk 加入。
"""

import rumps

APP_NAME = "NetWatch"
VERSION = "1.0.0"

# menu bar 圖示（用 emoji 當狀態指示）
ICON_UNKNOWN = "🌐"   # 啟動中 / 未知
ICON_ONLINE = "🟢"    # 已連線
ICON_OFFLINE = "🔴"   # 斷線


class NetWatchApp(rumps.App):
    def __init__(self):
        super().__init__(APP_NAME, title=ICON_UNKNOWN, quit_button=None)
        self.status_item = rumps.MenuItem("狀態：啟動中…")
        self.menu = [
            self.status_item,
            None,  # 分隔線
            rumps.MenuItem(f"{APP_NAME} v{VERSION}", callback=None),
            rumps.MenuItem("結束", callback=rumps.quit_application),
        ]


if __name__ == "__main__":
    NetWatchApp().run()
