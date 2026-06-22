import os
import socket
import subprocess
import time
import rumps
from datetime import datetime

APP_NAME = "NetWatch"
VERSION = "1.1.1"
ICON_UNKNOWN = "🌐"        
ICON_ONLINE = "🟢"       
ICON_OFFLINE = "🔴"       
ICON_UNSTABLE = "🟠"      
ICON_HIGH_LATENCY = "🟡"  
CHECK_INTERVAL = 1     
PROBE_TARGETS = [           
    ("1.1.1.1", 53),    #Cloudflare's DNS       
    ("8.8.8.8", 53),    #Google's DNS    
    ("9.9.9.9", 53),    #Quad9's DNS   
]
PROBE_TIMEOUT = 1           
FAIL_THRESHOLD = 2          
OK_THRESHOLD = 1           
LATENCY_WARN_MS = 300      
LATENCY_WARN_COUNT = 2     
FLAP_WINDOW = 60          
FLAP_THRESHOLD = 3        
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
SOUND_PATH = os.path.join(SCRIPT_DIR, "assets", "ping.mp3")
LOG_PATH = os.path.expanduser("~/Library/Logs/NetWatch.log")
def log_event(message):
    ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    try:
        os.makedirs(os.path.dirname(LOG_PATH), exist_ok=True)
        with open(LOG_PATH, "a") as f:
            f.write(f"{ts}  {message}\n")
    except OSError:
        pass


def probe():
    for host, port in PROBE_TARGETS:
        start = time.monotonic()
        try:
            sock = socket.create_connection((host, port), PROBE_TIMEOUT)
            sock.close()
            return True, (time.monotonic() - start) * 1000
        except OSError:
            continue
    return False, None

def format_duration(seconds):
    seconds = int(round(seconds))
    if seconds < 60:
        return f"{seconds}s"
    m, s = divmod(seconds, 60)
    if m < 60:
        return f"{m}m {s}s"
    h, m = divmod(m, 60)
    return f"{h}h {m}m"


def play_sound():
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
        self.last_outage_item = rumps.MenuItem("Last outage: —")
        self.mute_item = rumps.MenuItem("Mute sound", callback=self.toggle_mute)
        self.menu = [
            self.status_item,
            self.latency_item,
            self.last_outage_item,
            None,
            self.mute_item,
            rumps.MenuItem("Open log", callback=self.open_log),
            rumps.MenuItem("Clear log", callback=self.clear_log),
            rumps.MenuItem(f"{APP_NAME} v{VERSION}", callback=None),
            rumps.MenuItem("Quit", callback=rumps.quit_application),
        ]
        self.online = None
        self.latency_ms = None
        self.muted = False
        self._fail_count = 0
        self._ok_count = 0
        self._slow_count = 0    
        self._transitions = []
        self._offline_since = None 
        self.last_outage = None   
        self.timer = rumps.Timer(self.check, CHECK_INTERVAL)
        self.timer.start()
    def toggle_mute(self, sender):
        self.muted = not self.muted
        sender.state = 1 if self.muted else 0
    def open_log(self, _sender):
        if not os.path.exists(LOG_PATH):
            log_event("(log created)")
        try:
            subprocess.Popen(["open", LOG_PATH])
        except OSError:
            pass
    def clear_log(self, _sender):
        try:
            if os.path.exists(LOG_PATH):
                os.remove(LOG_PATH)  
                rumps.notification(APP_NAME, "Log cleared", "The network log history has been wiped.")
            else:
                rumps.notification(APP_NAME, "Log empty", "There is no log file to clear.")
        except OSError:
            rumps.notification(APP_NAME, "Error", "Could not clear the log file.")
    def check(self, _timer=None):
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
        was = self.online
        self.online = online

        if was is None:
            if online is False:
                self._offline_since = time.monotonic()
            return

        self._transitions.append(time.monotonic())

        if online:
            duration = None
            if self._offline_since is not None:
                duration = time.monotonic() - self._offline_since
                self.last_outage = duration
                self._offline_since = None
            message = "You are back online."
            if duration is not None:
                message = f"Offline for {format_duration(duration)}."
            log_event(f"RECONNECTED ({message})")
            self.alert("Network restored", message)
        else:
            self._offline_since = time.monotonic()
            log_event("DISCONNECTED")
            self.alert("Network disconnected", "Your connection just dropped.")

    def update_display(self):
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
        if self.last_outage is None:
            self.last_outage_item.title = "Last outage: —"
        else:
            self.last_outage_item.title = f"Last outage: {format_duration(self.last_outage)}"

    def alert(self, title, message):
        if not self.muted:
            play_sound()
        try:
            rumps.notification(APP_NAME, title, message)
        except Exception:
            pass
if __name__ == "__main__":
    NetWatchApp().run()
