# reMarkable diary → custom shell ("my OS") — Part 1: shell frame + settings

**Date:** 2026-07-10
**Status:** ✅ Implemented (Home / Settings / Library shell; brand: SebbyCorp Notepad)
**See also:** `2026-07-10-remarkable-sebbycorp-notepad-status.md`

## Goal

Turn the single-screen takeover diary into a **multi-screen shell** that owns the device:
it boots into a **Home** launcher, from which you enter **Write/Diary**, **Library**, and
**Settings**. This is Part 1 of the bigger "my OS" vision — it builds the skeleton +
a working Settings screen. Library (browse the whole reMarkable collection) and the
zoom/scroll canvas plug into this frame in later parts.

## Decisions (from brainstorming)

| Question | Decision |
|---|---|
| First piece | **Shell + Settings frame** (the skeleton) |
| Library scope (later) | **Whole reMarkable notebook collection** (big; a later part) |
| Boots into it | ✅ done (watchdog) |

## Architecture: a screen state machine

`diary.c` gains a top-level `screen` mode: `HOME`, `DIARY`, `LIBRARY`, `SETTINGS`. The main
loop routes input and drawing by the active screen. The current takeover behavior becomes
the **DIARY** screen.

- **HOME (launcher)** — title + large tap tiles: **Write**, **Library**, **Settings**,
  **Exit to reMarkable**. Drawn in Special Elite. This is the boot screen.
- **DIARY** — today's writing + AI takeover, unchanged, plus a **Home** control (corner)
  to return to the launcher. Its `library >` corner is repointed to the in-app **LIBRARY**
  screen (no more bounce to xochitl).
- **LIBRARY** — **stub this part**: a screen that says "Your notebooks — coming soon" with
  a Home control. Becomes the real browser in a later part (whole-collection scope).
- **SETTINGS** — a list of options you tap to change; persisted to `/home`.
- **Exit to reMarkable** — explicit action from HOME (and Settings): stops the shell,
  starts xochitl. The *only* path back to stock reMarkable now (deliberate).

Navigation: a consistent **Home** target (top-left corner) on every non-home screen; HOME
has the tiles. Input is dispatched to a per-screen handler so screens stay isolated and
testable.

## Settings (persisted to `/home/root/diary.conf`, `key=value`, loaded at boot)

| Setting | Values | Effect |
|---|---|---|
| Default model | agw-model-gpt5.5 / claude-fable-5 / grok4.5 / qwen3.6 | which model DIARY starts on |
| Response size | Small / Medium / Large | maps to RESP_PX (e.g. 30 / 36 / 48) |
| Response font | Typewriter / Cursive | Special Elite vs Dancing Script for answers |
| Idle-to-ask | 4 / 6 / 10 s | pause before the page is sent to AI |
| Screen sleep | Never / 10 min / 30 min | prevents the Wi-Fi doze/lockout when Never |
| Exit to reMarkable | (action) | hand back to xochitl |

- A tiny config module: `settings_load()` at boot, `settings_save()` on change. Missing
  file → sensible defaults. DIARY reads these at entry (model, size, font, idle).
- Each row: label + current value; tap cycles the value and saves.

## Data flow
- Boot → shell starts at HOME (or DIARY if a "start on diary" preference is set — default
  HOME) → user taps a tile → screen switches → per-screen input/draw → Home returns.
- Settings changes write `diary.conf` immediately and take effect on next DIARY entry.

## Error handling
- Unreadable/absent `diary.conf` → defaults, and rewrite a fresh one.
- Unknown screen → HOME.
- Exit-to-reMarkable reuses the proven detached rm2fb-kill + `systemctl start xochitl`.

## Testing
- Off-device: settings parse/serialize round-trip (unit test the tiny config module).
- On-device: boot → HOME tiles draw; enter each screen and Home-back; change each setting,
  confirm it persists across a diary restart (systemd) and changes DIARY behavior; Exit to
  reMarkable works; watchdog still boots into HOME.

## Out of scope (this part)
- **Real Library browser** (whole-collection) — stub now, its own part next.
- **Zoom/scroll canvas** — separate spec, plugs in as the DIARY surface later.
- Per-notebook/document management, sync, search.
- Theming beyond the existing paper/Special-Elite look.

## Sequencing (the bigger "my OS")
1. **This part** — shell frame + Settings.
2. **Library** — browse/open the whole reMarkable collection in-app.
3. **Canvas** — zoom/scroll writing surface as the DIARY screen (already spec'd).
