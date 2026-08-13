# reMarkable notepad — Teleprompter

**Date:** 2026-08-13
**Status:** Approved design (not implemented)
**Device:** reMarkable 2 / SebbyCorp Notepad (`diary.c`)
**Scripts:** public repo `sebbycorp/web-telepromotor`, folder `scripts/*.md`
**See also:** `2026-07-10-remarkable-sebbycorp-notepad-status.md`, `2026-07-10-remarkable-diary-shell-settings-design.md`

## Goal

Hold the tablet in front of you as a teleprompter while talking. A new Home row opens a script list pulled live from GitHub, then a black full-screen stage that shows one spoken line at a time.

## Decisions (from brainstorming)

| Question | Decision |
|---|---|
| Where | On the tablet, new Home row. Not a web-app change. |
| Motion | Hybrid: tap to step; optional play auto-advances. |
| Look | Stage: black field, white type. List: paper chrome like Library. |
| Hold | Portrait only. No rotate in this part. |
| Script source | Hardcoded `sebbycorp/web-telepromotor/scripts/`. Live fetch. No cache. No other repos. |
| What is spoken | Blockquote (`>`) lines only. Drop headings, `[VISUAL]`, `**HOST:**` labels, YouTube description, title options. |
| Implementation | Native screens inside `diary.c`. No sidecar binary. No deploy-time copy of scripts. |

## Architecture

`diary.c` already routes on `screen`: `SCR_HOME`, `SCR_DIARY`, `SCR_LIBRARY`, `SCR_SETTINGS`. Add two modes:

- `SCR_PROMPTER` — script list (paper)
- `SCR_PROMPTER_RUN` — stage (inverted)

Home grows one secondary card under Library: **Teleprompter** / `scripts from GitHub`. Existing Write / Library / Settings / Sleep / Exit hit zones shift down as needed so they do not overlap. Home from list returns to notepad Home. Home from stage returns to the list (not all the way Home).

Fetch is read-only HTTP GET. Prefer `curl` on the tablet to:

1. `https://api.github.com/repos/sebbycorp/web-telepromotor/contents/scripts`
2. each file’s `download_url` after tap

TLS: use `curl` on the tablet (`popen`, 15 s timeout, follow redirects, GitHub `Accept: application/vnd.github+json` on the contents call). Probe once at first fetch (`curl --version`). If `curl` is missing or cannot speak HTTPS, retry the same URLs via a one-line gateway hop: plaintext GET to `GW_IP` on a new small proxy path that only allows those two GitHub hosts. The hop is fallback, not a second product path — the user still sees “scripts from GitHub.” If both fail, show the can’t-reach error.

Parser is a small pure function (own `.c` / header or a clearly bounded section) so it can be unit-tested off-device.

```
HOME  --tap Teleprompter-->  SCR_PROMPTER  --tap .md-->  SCR_PROMPTER_RUN
  ^                            |  Home                     |  Home
  +----------------------------+                           +--> list
```

## Components

### Home card

- Same `draw_card` language as Library / Settings.
- Label: `Teleprompter`
- Subtitle: `scripts from GitHub`
- Tap: `enter_screen(SCR_PROMPTER)` and kick off the list fetch.

### Script list (`SCR_PROMPTER`)

- Paper background, Atkinson UI font, Home corner (same 140×170 target as other screens).
- Header: `Teleprompter`
- Quiet hint: `sebbycorp/web-telepromotor`
- One tappable row per `*.md` file, filename without extension as the title, subtitle `markdown`. Do not fetch file bodies to decorate the list.
- While the list fetch is in flight: one status line, `Loading scripts…`
- Non-`.md` entries from the GitHub contents API are ignored.

### Stage (`SCR_PROMPTER_RUN`)

- Full-screen black (`gray565(0)`), white type, portrait.
- Type: existing UI face (Atkinson), large — target ~48–56 px so a line is readable at arm’s length. Wrap to the content width with left/right margins (~80 px).
- Current spoken step only. Next step is not previewed (keeps the stage calm and avoids extra e-ink work).
- Chrome, low-contrast (dark grey, not white):
  - Top-left: Home
  - Top-right: `play` / `pause` (same control, toggles)
  - Bottom: `i / n` step index (1-based)
- Input:
  - Tap y < ~15% of height, and not on Home/play: previous step (clamp at 0).
  - Tap elsewhere except chrome: next step (clamp at last).
  - Play on: a ~4.0 s timer advances one step. Tap next/back still works. Reaching the last step turns play off and stays on that step. No wrap.
- Leaving the stage forgets the index. Re-opening a script starts at step 0.

### Play timer

- Fixed 4.0 seconds per step. Not persisted. No Settings row in this part.
- Implemented with the existing main-loop clock (same style as idle-to-ask), not a new thread.

## Data flow

1. Enter `SCR_PROMPTER` → GET GitHub contents for `scripts/` → keep files whose name ends in `.md` → store name + `download_url` → draw list.
2. Tap a row → GET `download_url` → parse markdown into a `char**` of spoken steps → if count > 0, enter `SCR_PROMPTER_RUN` at index 0.
3. Stage input only moves `prompter_i` in `[0, prompter_n)`.
4. Home on stage frees or retains the step array until the next successful load (either is fine; must not leak). Home on list does not need to keep the GitHub listing.

### Parser (normative)

A **step** is one markdown blockquote block:

- A line that, after optional leading whitespace, starts with `>` is a quote line.
- Strip the leading `>`, optional following space, and collect consecutive quote lines into one step.
- A blank line (or a non-quote line) ends the current step.
- Adjacent quote lines with no blank between them are **one step**, unless the wrapped rendering would exceed the stage text box. Then split on sentence-ending `.`, `?`, or `!` followed by a space or end-of-string. Never split mid-word. If a single sentence still overflows, hard-wrap by words onto multiple *drawn* lines of the **same** step (user still taps once for the whole sentence).
- Non-quote lines are discarded: ATX headings, `**HOST:**`, `**[VISUAL:…]**`, horizontal rules, the YouTube description section, title options, and any other body text.

Example: the first HOST block in `scripts/agent-registry.md` becomes two steps if it is two blockquote paragraphs separated by a blank quote-line, or one step if they are a single contiguous quote.

### Persistence

- None for scripts, position, or play speed.
- No writes to GitHub.
- No new `diary.conf` keys in this part.

## Error handling

Stay on the list (paper). Never enter a blank stage.

| Failure | UI |
|---|---|
| No Wi-Fi, curl/connect error, GitHub 4xx/5xx, gateway hop down | `Can't reach GitHub. Check Wi-Fi.` Home still works. |
| Contents API ok but zero `*.md` files | `No scripts in scripts/.` |
| File GET fails after tap | Status line on the list: `Couldn't load <name>.` Stay on list. |
| File loads but parser returns 0 steps | `No spoken lines in this file.` Stay on list. |
| Play on last step | Pause. Stay on last step. |

Re-entering Teleprompter from Home is the refetch. No auto-retry loop.

## Testing

### Off-device

Unit-test the parser (and wrap/split helpers) against checked-in fixtures:

- `scripts/agent-registry.md` (or a copied fixture): only HOST quote text; zero hits for `YouTube Description`, `Title options`, `[VISUAL`, or `## `.
- File with no `>` lines → 0 steps.
- One long sentence → still one step, word-wrapped for draw.
- Two sentences in one over-tall quote → split into two steps on `. `.
- Empty file / whitespace only → 0 steps.

### On-device

- Home shows Teleprompter; Write / Library / Settings still open and return.
- Wi-Fi on → list includes `agent-registry`, `virtual-mcp`, `example` (current repo contents).
- Wi-Fi off → can’t-reach message.
- Open `agent-registry` → first spoken line on black. Tap next/back. Play advances and stops on the last line.
- Home from stage → list. Home from list → notepad Home.

## Out of scope

- Landscape / rotate.
- Remote control from a second device.
- Offline script cache.
- Configurable owner/repo.
- Speed slider, font-size slider, countdown timer, mirror/flip.
- Showing section cues or raw markdown.
- Editing scripts on the tablet.
- Writing or committing back to GitHub.

## Code touchpoints

| Path | Change |
|---|---|
| `k8s-goose/remarkable-diary/takeover/diary.c` | New screens, Home card, input, stage draw, fetch glue |
| New parser module next to `diary.c` (preferred) or a bounded section inside it | Markdown → steps |
| Off-device test binary (same pattern as `test_lasso.c`) | Parser fixtures |
| `docs/superpowers/specs/2026-07-10-remarkable-sebbycorp-notepad-status.md` | Update UX map after ship |

Deploy remains `./deploy.sh` to the tablet. No new systemd unit.
