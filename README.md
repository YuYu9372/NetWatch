# NetWatch

A tiny native macOS menu bar app (C++ / Objective-C++) that alerts you when
your internet connection drops and when it comes back — with a sound and a
notification — and shows what your Wi-Fi is doing.

Connectivity is checked against several targets (Cloudflare, Google, Quad9),
so a single provider being down won't trigger a false alarm. Every drop and
recovery is logged to `~/Library/Logs/NetWatch.log`.

## Build & run

Requires macOS 11+ and the Xcode Command Line Tools.

```
make        # builds build/NetWatch.app
make run    # builds and launches it
```

## Menu

```
🟢 Status: Connected / Unstable (N drops / 10 min) / Disconnected
Speed: Fast · 245 Mbps ↓ / 40 Mbps ↑ (tested 00:41)   ← click to run a test
Wi-Fi: <network name>
────
RSSI: -63 dBm (Fair)
SNR: 28 dB
Link: 288 Mbps
Channel: 44 (5 GHz, 160 MHz)
Security: WPA2 Personal
IP: 192.168.31.23
Public IP: 203.0.113.7
Last outage: 10/01 00:08:24 (58s)
────
Mute sound
HUD ▸ Emoji / Ping / RSSI
Color ▸ Ping / Outage / RSSI
Update interval ▸ 1 / 3 / 5 / 10 / 20 / 30 / 60 / 90 sec
Open log
Clear log ▸ Sure?
NetWatch v2.0.0
Quit
```

- **HUD** picks what the menu bar shows: a colored dot (Emoji), latency
  (`14ms`), or signal (`-63dBm`).
- **Color** picks which metric colors it.
- 🔴 / red appears **only** when disconnected, whatever HUD and Color are set to.
- HUD, Color, interval and mute are remembered between launches.

### Colors

| Color metric | 🟢 | 🟡 | 🟠 |
| --- | --- | --- | --- |
| Ping | under 40 ms | 40–90 ms | over 90 ms |
| Outage (drops in last 10 min) | 0–1 | 2–4 | 5+ |
| RSSI | -50 dBm or higher | -51 to -67 | -68 or lower |

RSSI is signal strength in dBm (negative; closer to 0 is stronger). SNR is
signal minus noise — higher is better.

### Speed

Clicking **Speed** runs macOS's built-in `networkQuality` test (up to 20 s).
It downloads real data, so it only runs when you click. Labels: Fast ≥ 100 Mbps
down, Normal 25–100, Slow under 25.

### Wi-Fi name

macOS only reveals the Wi-Fi name to apps with Location permission, so NetWatch
asks for it once. Without it the row reads "Allow Location to show name";
everything else works. Because the build is ad-hoc signed, macOS may ask again
after a rebuild.

### Public IP

Fetched from `https://1.1.1.1/cdn-cgi/trace` at launch, on reconnect, and when
the menu opens (at most every 30 s). With a VPN such as Cloudflare WARP on, it
shows the VPN's address.

## Log

```
2026-10-01 00:08:24  DISCONNECTED (Wi-Fi -63 dBm, Fair)
2026-10-01 00:09:22  RECONNECTED (Offline for 58s.)
```

Each drop records the Wi-Fi signal at that moment: a strong signal while offline
points at the router or ISP; a lost or weak signal points at Wi-Fi.

## Settings

Thresholds and timings are constants near the top of `src/NetWatch.mm`
(`FailThreshold`, `FlapWindowSeconds`, `OutageWindowSeconds`, `PingGoodMs`,
`RssiGoodDbm`, …).

## Sound

The alert sound is `assets/ping.mp3`. To change it, replace that file (keep
the same name).

## Backup

Older versions are kept in `.backup/`:

- `.backup/python-1.1.4/` — the original Python (rumps) app
- `.backup/cpp-1.2.0/` — the C++ app before the 2.0.0 redesign

## Version

- 2.0.0 — C++ only. New menu: speed test, Wi-Fi name, RSSI/SNR/link/channel/security, local and public IP, last outage time; HUD (Emoji/Ping/RSSI) and Color (Ping/Outage/RSSI) options; 🔴 only when disconnected; settings remembered. Python version moved to `.backup/`.
- 1.2.0 — show Wi-Fi signal (dBm, SNR), link rate and channel; log signal on disconnect; optional menubar color by signal.
- 1.1.3 — change the offline icon back.
- 1.1.0 — multiple probe targets, outage duration on reconnect, and an outage log. Also fixed some issue :D
- 1.0.2 — faster disconnect detection; debounce 🟡 so it no longer flashes at cutoff.
- 1.0.1 — add 🟠 unstable (flapping) and 🟡 high-latency states.
- 1.0.0 — first release.
