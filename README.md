# NetWatch

A tiny macOS menu bar app that alerts you when your internet connection drops
and when it comes back — with a sound and a notification.

- 🟢 Connected
- 🔴 Disconnected

When the connection drops, NetWatch plays a ping and shows a notification.
When it recovers, it plays the ping again. The menu bar icon always reflects
the current state.

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
| `PROBE_HOST` | `1.1.1.1` | Host used to test connectivity |

## Sound

The alert sound is `assets/ping.mp3`. To change it, replace that file
(keep the same name), or edit `SOUND_PATH` in `netwatch.py`.

## Version

1.0.0 — first release.
