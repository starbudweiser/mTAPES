# mTAPES

A native macOS screen recorder that edits your demos for you, and that any AI can drive through MCP.

🇬🇧 English · 🇫🇷 [Français](#français)

## About

mTAPES is made by Starbudweiser & Claude Code (Anthropic). Part of the **DESKTOP MAC TOOLKIT**. MIT License, © 2026 Starbudweiser. Provided as is, without warranty. An "About mTAPES" window will be available in the app menu once the app exists.

## Status

**Early preview (0.1.x).** Today mTAPES is a menu-bar app with a Simple mode that records the whole screen or one window (shortcut ⌥⌘R) and saves a `.tape` take in `~/Movies/mTAPES`,
plus a command-line recording engine (`mtapes`). **Not built yet:** automatic editing, export, AI and MCP control, Advanced mode, audio, automatic updates. Requires **macOS 15 or later on Apple Silicon**
and the Screen Recording permission. Design mockups: [`maquettes/index.html`](maquettes/index.html) (open it in a browser); plan: [`ARCHITECTURE.md`](ARCHITECTURE.md) (French).

## Planned

- Two modes in one app: **Simple** (what to film, which style, Record) and **Advanced** (finishing timeline, AI/MCP control, full settings), with a setup assistant.
- **Record the way you want**: a screen, a window (even hidden), an application, or a zone.
- **Automatic finishing**: zooms on clicks, dead time sped up, smoothed cursor, click effects, frame and background, 16:9 / 9:16 / 1:1.
- **AI editing**: one button, three variants, every decision explained and undoable; free on-device engines first (Apple Intelligence, local models), rules-based fallback, nothing leaves the Mac by default.
- **MCP server** so Claude Code, Codex, Cursor or any other AI can start a recording, announce its clicks, and get a finished demo (GIF for a README, MP4 for a release, vertical video for social networks).
- Light files: adaptive frame rate, hardware HEVC, optimized GIF.

## What works today: the engine

`mtapes` records into a `.tape` package (raw HEVC video, `events.jsonl`, `pointer.bin`, `meta.json`):

- ScreenCaptureKit capture of a display, a window, an application or a zone; the cursor is not baked into the video.
- Adaptive frame rate (only changed frames are written), hardware HEVC with constant quality, a key frame every second, fragmented file (a crash leaves a playable file).
- Click, double-click and drag detection from the button state (no extra permission; a press shorter than ~8 ms can be missed).
- Crash-tolerant takes: the video is fragmented and events are saved every 5 s (verified with a forced kill).

```sh
swift build -c release
.build/release/mtapes doctor                       # permissions, hardware encoder
.build/release/mtapes targets                      # displays, windows, applications
.build/release/mtapes record --seconds 10 --out ~/Movies/mTAPES --profile balanced
.build/release/mtapes bench --seconds 20           # CPU, dropped frames, size, latency
```

First measurements are in [`bench/RESULTS.md`](bench/RESULTS.md) (Apple M5 Max, 3440 × 1440: no frame refused by the encoder over a 30-minute take, about 10 MB per minute at the Balanced profile, about 0.2 CPU core attributable to recording). They are early and incomplete (visual quality, long recordings and comparisons are not measured yet); only measured numbers will be published. Requires macOS 15 or later on Apple Silicon and the Screen Recording permission.

---

## Français

Un enregistreur d'écran macOS natif qui monte vos démos tout seul, et que n'importe quelle IA peut piloter par MCP.

**À propos** : mTAPES est réalisé par Starbudweiser & Claude Code (Anthropic). Fait partie du **DESKTOP MAC TOOLKIT**. Licence MIT, © 2026 Starbudweiser. Fourni en l'état, sans garantie.

**État** : développement précoce, seul le moteur d'enregistrement existe (ligne de commande). Maquettes : [`maquettes/index.html`](maquettes/index.html) ; plan : [`ARCHITECTURE.md`](ARCHITECTURE.md). Premiers chiffres mesurés : [`bench/RESULTS.md`](bench/RESULTS.md).
