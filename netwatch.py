#!/usr/bin/env python3
"""NetWatch - a macOS menu bar network drop alert tool.

Version 1.0.0: menu bar icon + periodic connectivity check (with debounce).
Sound and notifications are added in a later chunk.
"""

import socket

import rumps

APP_NAME = "NetWatch"
VERSION = "1.0.0"

# Menu bar icons (emoji used as status indicator)
ICON_UNKNOWN = "🌐"   # starting up / unknown
ICON_ONLINE = "🟢"    # connected
ICON_OFFLINE = "🔴"   # disconnected

# --- Detection settings ---
CHECK_INTERVAL = 5          # seconds between checks
PROBE_HOST = "1.1.1.1"      # probe target (Cloudflare DNS)
PROBE_PORT = 53             # DNS port
PROBE_TIMEOUT = 2           # per-attempt connect timeout (seconds)
FAIL_THRESHOLD = 2          # consecutive failures before marking offline (debounce)
OK_THRESHOLD = 1            # consecutive successes before marking online


def is_connected():
    """Try to open a TCP connection to PROBE_HOST; success means online."""
    try:
        sock = socket.create_connection((PROBE_HOST, PROBE_PORT), PROBE_TIMEOUT)
        sock.close()
        return True
    except OSError:
        return False


class NetWatchApp(rumps.App):
    def __init__(self):
        super().__init__(APP_NAME, title=ICON_UNKNOWN, quit_button=None)
        self.status_item = rumps.MenuItem("Status: starting…")
        self.menu = [
            self.status_item,
            None,  # separator
            rumps.MenuItem(f"{APP_NAME} v{VERSION}", callback=None),
            rumps.MenuItem("Quit", callback=rumps.quit_application),
        ]

        # State: None = unknown, True = online, False = offline
        self.online = None
        self._fail_count = 0
        self._ok_count = 0

        # Timer (runs on the main thread; rumps schedules it)
        self.timer = rumps.Timer(self.check, CHECK_INTERVAL)
        self.timer.start()

    def check(self, _timer=None):
        """Called on each tick: probe network, apply debounce, update state."""
        if is_connected():
            self._ok_count += 1
            self._fail_count = 0
            if self.online is not True and self._ok_count >= OK_THRESHOLD:
                self.set_online(True)
        else:
            self._fail_count += 1
            self._ok_count = 0
            if self.online is not False and self._fail_count >= FAIL_THRESHOLD:
                self.set_online(False)

    def set_online(self, online):
        """Switch state and update the menu bar display."""
        self.online = online
        if online:
            self.title = ICON_ONLINE
            self.status_item.title = "Status: Connected"
        else:
            self.title = ICON_OFFLINE
            self.status_item.title = "Status: Disconnected"


if __name__ == "__main__":
    NetWatchApp().run()
