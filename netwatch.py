#!/usr/bin/env python3
"""NetWatch - a macOS menu bar network drop alert tool.

menu bar icon + periodic connectivity check (with debounce), plays a sound and
shows a notification when the connection drops or recovers. Also shows 🟠 when
the connection keeps flapping and 🟡 when latency is high (visual only).
"""

import os
import socket
import subprocess
import time

import rumps

APP_NAME = "NetWatch"
VERSION = "1.0.2"

ICON_UNKNOWN = "🌐"        # starting up / unknown
ICON_ONLINE = "🟢"         # connected
ICON_OFFLINE = "🔴"        # disconnected
ICON_UNSTABLE = "🟠"       # connection keeps flapping
ICON_HIGH_LATENCY = "🟡"   # connected but slow

CHECK_INTERVAL = 2          # seconds between checks
PROBE_TARGETS = [           # probe these in order; offline only if ALL fail
    ("1.1.1.1", 53),        # Cloudflare DNS
    ("8.8.8.8", 53),        # Google DNS
    ("9.9.9.9", 53),        # Quad9 DNS
]
PROBE_TIMEOUT = 1           # per-attempt connect timeout (seconds)
FAIL_THRESHOLD = 2          # consecutive failures before marking offline (debounce)
OK_THRESHOLD = 1            # consecutive successes before marking online
LATENCY_WARN_MS = 300       # connect slower than this -> high latency (yellow)
LATENCY_WARN_COUNT = 2      # consecutive slow readings before showing yellow
FLAP_WINDOW = 60            # seconds window used to detect flapping
FLAP_THRESHOLD = 3          # transitions within the window -> unstable (orange)

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
SOUND_PATH = os.path.join(SCRIPT_DIR, "assets", "ping.mp3")


def probe():
    """Try each target in PROBE_TARGETS until one connects.

    Returns (ok, latency_ms). Online (and latency) is reported from the first
    target that responds; only when every target fails is it considered offline.
    """
    for host, port in PROBE_TARGETS:
        start = time.monotonic()
        try:
            sock = socket.create_connection((host, port), PROBE_TIMEOUT)
            sock.close()
            return True, (time.monotonic() - start) * 1000
        except OSError:
            continue
    return False, None


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
        self.latency_item = rumps.MenuItem("Latency: —")
        self.mute_item = rumps.MenuItem("Mute sound", callback=self.toggle_mute)
        self.menu = [
            self.status_item,
            self.latency_item,
            None,
            self.mute_item,
            rumps.MenuItem(f"{APP_NAME} v{VERSION}", callback=None),
            rumps.MenuItem("Quit", callback=rumps.quit_application),
        ]

        self.online = None
        self.latency_ms = None
        self.muted = False
        self._fail_count = 0
        self._ok_count = 0
        self._slow_count = 0    # consecutive high-latency readings (for yellow debounce)
        self._transitions = []  # monotonic timestamps of recent online<->offline flips

        self.timer = rumps.Timer(self.check, CHECK_INTERVAL)
        self.timer.start()

    def toggle_mute(self, sender):
        self.muted = not self.muted
        sender.state = 1 if self.muted else 0

    def check(self, _timer=None):
        """Called on each tick: probe network, apply debounce, update state."""
        ok, self.latency_ms = probe()
        if ok and self.latency_ms is not None and self.latency_ms > LATENCY_WARN_MS:
            self._slow_count += 1
        else:
            self._slow_count = 0
        if ok:
            self._ok_count += 1
            self._fail_count = 0
            if self.online is not True and self._ok_count >= OK_THRESHOLD:
                self.set_online(True)
        else:
            self._fail_count += 1
            self._ok_count = 0
            if self.online is not False and self._fail_count >= FAIL_THRESHOLD:
                self.set_online(False)
        self.update_display()

    def set_online(self, online):
        """Update connectivity state and alert on a real transition."""
        was = self.online
        self.online = online

        if was is None:
            return

        # Record this real transition for flapping detection.
        self._transitions.append(time.monotonic())

        if online:
            self.alert("Network restored", "You are back online.")
        else:
            self.alert("Network disconnected", "Your connection just dropped.")

    def update_display(self):
        """Pick the menu bar icon + status text by precedence."""
        now = time.monotonic()
        self._transitions = [t for t in self._transitions if now - t <= FLAP_WINDOW]
        flaps = len(self._transitions)
        unstable = flaps >= FLAP_THRESHOLD

        high_latency = self._slow_count >= LATENCY_WARN_COUNT
        if self.online is False:
            self.title = ICON_OFFLINE
            status = "Disconnected"
        elif unstable:
            self.title = ICON_UNSTABLE
            status = f"Unstable ({flaps} flaps/min)"
        elif high_latency:
            self.title = ICON_HIGH_LATENCY
            status = f"High latency ({int(self.latency_ms)} ms)"
        elif self.online:
            self.title = ICON_ONLINE
            status = "Connected"
        else:
            self.title = ICON_UNKNOWN
            status = "starting…"
        self.status_item.title = f"Status: {status}"
        if self.latency_ms is None:
            self.latency_item.title = "Latency: —"
        else:
            self.latency_item.title = f"Latency: {int(self.latency_ms)} ms"

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
