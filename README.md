# NetWatch

A tiny macOS menu bar app that alerts you when your internet connection drops
and when it comes back — with a sound and a notification.

- 🟢 Connected
- 🔴 Disconnected
- 🟠 Unstable — the connection keeps flapping (dropping in and out)
- 🟡 High latency — still online, but slow to respond

When the connection drops, NetWatch plays a ping and shows a notification.
When it recovers, it plays the ping again and tells you how long you were
offline. The unstable and high-latency states are visual only (no sound).
The menu bar icon always reflects the current state, with this precedence:
🔴 > 🟠 > 🟡 > 🟢.

Connectivity is checked against several targets (Cloudflare, Google, Quad9),
so a single provider being down won't trigger a false alarm. Every drop and
recovery is logged to `~/Library/Logs/NetWatch.log` — open it from the menu
via **Open log**. The menu also shows the current latency and the duration of
the last outage.

## Requirements

- macOS
- Python 3

## Setup

From the project folder:

```bash
pip3 install -r requirements.txt
```

## Run

```bash
python3 netwatch.py
```

A 🌐 icon appears in the menu bar and switches to 🟢 / 🔴 as your network
changes. Use the menu to mute the sound or quit.

## Settings

Edit the constants near the top of `netwatch.py`:

| Setting | Default | Meaning |
| --- | --- | --- |
| `CHECK_INTERVAL` | `5` | Seconds between checks |
| `FAIL_THRESHOLD` | `2` | Consecutive failures before "disconnected" (debounce) |
| `OK_THRESHOLD` | `1` | Consecutive successes before "connected" |
| `PROBE_TARGETS` | Cloudflare/Google/Quad9 | Hosts tried in order; offline only if all fail |
| `LATENCY_WARN_MS` | `300` | Connect slower than this → 🟡 high latency |
| `LATENCY_WARN_COUNT` | `2` | Consecutive slow readings before showing 🟡 |
| `FLAP_WINDOW` | `60` | Seconds window used to detect flapping |
| `FLAP_THRESHOLD` | `3` | Transitions within the window → 🟠 unstable |

## Sound

The alert sound is `assets/ping.mp3`. To change it, replace that file
(keep the same name), or edit `SOUND_PATH` in `netwatch.py`.

## Version

- 1.1.0 — multiple probe targets, outage duration on reconnect, and an outage log.
- 1.0.2 — faster disconnect detection; debounce 🟡 so it no longer flashes at cutoff.
- 1.0.1 — add 🟠 unstable (flapping) and 🟡 high-latency states.
- 1.0.0 — first release.
