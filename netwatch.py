#!/usr/bin/env python3
"""NetWatch - a macOS menu bar network drop alert tool.

Version 1: menu bar icon + periodic connectivity check (with debounce),
plays a sound and shows a notification when the connection drops or recovers.
"""

import os
import socket
import subprocess

import rumps

APP_NAME = "NetWatch"
VERSION = "1.0.1"

ICON_UNKNOWN = "🌐"   # starting up / unknown
ICON_ONLINE = "🟢"    # connected
ICON_OFFLINE = "🔴"   # disconnected

CHECK_INTERVAL = 5          # seconds between checks
PROBE_HOST = "1.1.1.1"      # probe target (Cloudflare DNS)
PROBE_PORT = 53             # DNS port
PROBE_TIMEOUT = 2           # per-attempt connect timeout (seconds)
FAIL_THRESHOLD = 2          # consecutive failures before marking offline (debounce)
OK_THRESHOLD = 1            # consecutive successes before marking online

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
SOUND_PATH = os.path.join(SCRIPT_DIR, "assets", "ping.mp3")


def is_connected():
    """Try to open a TCP connection to PROBE_HOST; success means online."""
    try:
        sock = socket.create_connection((PROBE_HOST, PROBE_PORT), PROBE_TIMEOUT)
        sock.close()
        return True
    except OSError:
        return False


def play_sound():
    """Play the ping sound asynchronously via macOS `afplay`."""
    if not os.path.exists(SOUND_PATH):
        return
    try:
        subprocess.Popen(["afplay", SOUND_PATH])
    except OSError:
        pass


class NetWatchApp(rumps.App):
    def __init__(self):
        super().__init__(APP_NAME, title=ICON_UNKNOWN, quit_button=None)
        self.status_item = rumps.MenuItem("Status: starting…")
        self.mute_item = rumps.MenuItem("Mute sound", callback=self.toggle_mute)
        self.menu = [
            self.status_item,
            None,
            self.mute_item,
            rumps.MenuItem(f"{APP_NAME} v{VERSION}", callback=None),
            rumps.MenuItem("Quit", callback=rumps.quit_application),
        ]

        self.online = None
        self.muted = False
        self._fail_count = 0
        self._ok_count = 0

        self.timer = rumps.Timer(self.check, CHECK_INTERVAL)
        self.timer.start()

    def toggle_mute(self, sender):
        self.muted = not self.muted
        sender.state = 1 if self.muted else 0

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
        """Switch state, update display, and alert on a real transition."""
        was = self.online
        self.online = online

        if online:
            self.title = ICON_ONLINE
            self.status_item.title = "Status: Connected"
        else:
            self.title = ICON_OFFLINE
            self.status_item.title = "Status: Disconnected"

        if was is None:
            return

        if online:
            self.alert("Network restored", "You are back online.")
        else:
            self.alert("Network disconnected", "Your connection just dropped.")

    def alert(self, title, message):
        """Play sound + show a notification for a status change."""
        if not self.muted:
            play_sound()
        try:
            rumps.notification(APP_NAME, title, message)
        except Exception:
            pass


if __name__ == "__main__":
    NetWatchApp().run()
