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

## MCP: let an AI record and finish the demo

The app embeds an MCP server so Claude Code, Codex, Cursor or any MCP client can start a take, **announce each action it performs**, stop, then get a finished demo.
It is **off by default**: tick **AI control** in the mTAPES menu-bar menu (the icon then shows "IA"). A client must also be **allowed once** ("Allow <client>" in the same menu, or in the **AI control…** window); nothing is recorded before that.

- **One-click connection**: *AI control…* detects Claude Code, Claude Desktop, Cursor, Codex and Gemini CLI and connects them (your existing configuration is backed up and kept). Or by hand: `claude mcp add mtapes -- "/Applications/mTAPES.app/Contents/MacOS/mtapes-cli" mcp`.
- **Clients without a command line** can use the optional local HTTP server (`http://127.0.0.1:47321/mcp`, bearer token, this computer only).
- **Tools**: `tapes_list_targets`, `tapes_start` (screen, one window even if covered, one app, or a zone), `tapes_mark` (click, type, scroll, key, chapter, with position and a human label; `space=window` for window-relative positions), `tapes_status`, `tapes_stop`, `tapes_list`,
  `tapes_finish` (plan zooms on the marked actions, speed up dead time, caption from your labels) and `tapes_export` (`readme` = light GIF, `release` = 1080p MP4, `short` = vertical 9:16 MP4).
- Screen commands go to the app (which holds the Screen Recording permission) over a private Unix socket (mode 600, same user only); finishing and export run in the MCP process, one render at a time. A take also stops by itself after `max_seconds` (default 600).
- Tests: `tests/mcp_e2e.py` (a real take driven over MCP, finished and exported).

## Automatic finishing

A take is raw and untouched; the finishing layer (`finition.json`) is recomputed at will: zooms (eased) on the actions, dead time sped up, smoothed cursor redrawn with click ripples, captions from the labels the AI announced (never invented), rounded window on a gradient background with shadow, 16:9 or 9:16.
`mtapes finish TAPE --preset release` then `mtapes export TAPE --dest release`. On a synthetic 8.8 s source the render takes about 1.4 s (1080p60) to 2 s (GIF); real demos have not been measured yet.

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
