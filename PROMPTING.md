# AI auto-edit — prompting guide

mTAPES does not need its own AI: the assistant you already use (Claude, Codex, Gemini, Cursor…) edits the take through MCP, at no extra cost.

## Fastest: one sentence

> Record a demo of my app doing X with mTAPES, then edit it for a README GIF.

The assistant records (`tapes_start`, `tapes_mark` after each action, `tapes_stop`), then edits (`tapes_summary` → `tapes_apply_plan`) and exports (`tapes_export`).
In clients that support MCP prompts, pick **edit_demo** to load the full editing guide.

## What the assistant sees

`tapes_summary` returns the duration, every mark (time, kind, position 0–1 across the filmed image, label, `outside: true` if off the picture) and the current plan.
`frames` (1–6) or `frame_times` adds small screenshots so it can look at the screen.

## What it decides — `tapes_apply_plan`

| Section | Fields | Limits |
|---|---|---|
| `zooms` | `from_s`, `to_s`, `x`, `y`, `scale` | scale 1.1–3, ≥ 0.5 s, 40 max |
| `speeds` | `from_s`, `to_s`, `factor` | factor 0.25–16, ≥ 0.5 s, no overlap |
| `captions` | `from_s`, `to_s`, `text` | ≤ 80 characters, ≥ 0.5 s |
| `cursor` | `show`, `ripple`, `size_percent` | 50–300 |

Times are seconds of the raw take. Omitted sections keep the current plan. Everything is validated and clamped; the reply lists `warnings` and the final `film_duration_s`. The raw take is never modified.

## Rules of thumb (also in the `edit_demo` prompt)

- One zoom per action cluster, 1.6–2.2 for a button, 1–3 s, at most one every ~3 s.
- Speed up any stretch with no action for more than 2 s (×3–8), keeping 0.5–1 s at normal speed around actions.
- Captions: 2–6 words, from your own mark labels, 1.5–2.5 s each.
- Length: README GIF 15–45 s, release 30–90 s, short under 45 s.

## Prompts that work

- "Edit it tighter: under 30 s, speed up everything that isn't an action."
- "Zoom closer on the buttons and add a caption for each step."
- "Make a vertical short for social media."
- "Show me frames at 5 s and 12 s, then fix the zoom that misses the button."
