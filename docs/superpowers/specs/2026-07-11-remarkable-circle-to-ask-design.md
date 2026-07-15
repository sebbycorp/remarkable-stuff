# Circle-to-Ask — design

**Date:** 2026-07-11
**Component:** SebbyCorp Notepad takeover diary (`diary.c`)
**Source:** `/Users/sebbycorp/src/k8s-goose/remarkable-diary/takeover/diary.c` (branch `feat/agent-desk`)

## Problem

Today the `AI: on/off` footer toggle means "answer the whole page." When AI is on,
every pen stroke extends one page-wide bounding box (`bx0..bx1`); after an idle
pause (~6 s) that entire box is cropped → OCR → answer rendered underneath
(`diary.c:1972`).

The user wants a more precise trigger: keep an AI on/off button, but instead of
answering everything, **circle the specific thing you want answered**. The circle
is both the selection and the "send it" command — its contents are OCR'd to text
and sent to the AI, which answers below.

## Interaction model

- The `AI: on/off` footer button stays. Its meaning changes:
  **on = "listening for a circle," off = plain writing, nothing ever sends.**
- With AI **on**, the user writes normally. When they draw a **big closed loop**
  around something, the app:
  1. recognizes it as a lasso (not a letter or doodle),
  2. **erases the loop ink** (it was a command, not content),
  3. flashes a highlight box around the circled region for feedback,
  4. OCRs *only that region* → sends to the currently selected model,
  5. renders the answer **just below the circled area** (falls back to
     page-bottom if there is no room below).
- The previous behavior — *AI on answers the whole page after a pause* — is
  **removed**. Circling is now the only trigger. When AI is off, circles are
  plain ink and nothing sends.

## Lasso detection heuristic

A just-finished pen stroke is treated as a lasso **only when all of the following
hold, and only while `ai_on`**:

- **Freehand only** — the stroke must be the `PEN` tool. Shape tools
  (Ellipse/Rect/Line/Arrow) are never lassos, so the user can still *draw* a
  circle as content by selecting the Ellipse tool.
- **Closed** — the pen-up point is within ~60 px (screen) of the pen-down point.
- **Big** — the stroke's bounding box exceeds handwriting size in *both*
  dimensions (≳150 px canvas units). A written "O", "a", or "e" is far smaller,
  so normal writing will not fire it.
- If any condition fails, the stroke commits as normal ink — behavior identical
  to today.

Misfire escape hatch: turning AI off makes every circle plain ink again; a false
positive at worst appends an unwanted answer.

## Implementation (`diary.c`)

- **Per-stroke screen-space bbox** (`sbx0..sby1`): reset on pen-down, extended on
  each move alongside the existing ink draw (`diary.c:1964`). Also record the
  pen-down point for the "closed" test.
- **Pen-up of a PEN stroke** (`live_idx>=0` branch, `diary.c:1872`): add an
  `is_lasso(sbx0,sby0,sbx1,sby1, downx,downy, upx,upy)` check.
  - **If lasso:** pop the just-committed stroke via the existing undo path
    (`nst--`, `diary.c:166`), repaint that band, draw the highlight box, then call
    `ask_start(sbx0,sby0,sbx1,sby1,cur_model)` with
    `ask_anchor_y = sby1 + gap`. Do **not** extend the page-wide `bx0..bx1`
    accumulator for this stroke.
  - **If not lasso:** commit as ink (unchanged).
- **Remove the idle auto-ask block** (`diary.c:1972`). The page-wide `bx0..bx1`
  accumulator no longer triggers anything; `ask_start` receives the lasso's bbox
  directly. (The AI-toggle handler at `diary.c:1894` that arms/clears the page
  bbox on toggle is simplified accordingly — toggling AI on no longer needs
  `ARM_ASK()`.)
- **Reuse unchanged:** `capture_png`, and the async fork pipeline
  `ask_start` / `ask_poll` / `ask_render_result`. Only *what rectangle* is
  captured and *when* changes. Because the loop ink is erased before capture, the
  captured rectangle contains only the underlying writing.
- **Footer AI button:** keep the `AI: on/off` label; when on, show a hint such as
  "circle to ask."

## Edge cases

- **Empty selection** (loop around blank space) → OCR returns empty → existing
  "Could not read handwriting" toast.
- **Loop over bar/footer** → clamp the capture region to the canvas band using
  existing clamp logic; `capture_png` already clamps to screen bounds.
- **Multi-page** → the lasso bbox is inherently on the current page; no page-span
  concern.
- **Zoom** → geometry thresholds are evaluated in canvas units so they are
  zoom-independent; the capture region is converted to screen coords for
  `capture_png` (which reads the framebuffer).
- **AI busy** → ignore new lassos while `ask_busy` (existing guard).

## Testing / verification

- **Automated (no human):** drive a synthetic closed-loop stroke through the pen
  event path and assert `is_lasso()` returns true and `ask_start` is called with
  the loop's bbox — not the page bbox. Assert a small "O"-sized loop returns
  false. Use the existing env-gated hooks (`SHELL_SHOT=diary`, `capture_png`
  dumps) to visually confirm the highlight box and answer placement.
- **On-device:** one physical circle around handwritten text with AI on; confirm
  the loop ink disappears, the region highlights, and the answer lands below.
- **Deploy:** per usual flow — `systemctl stop diary.service` (frees the binary,
  rm2fb stays up via `KillMode=process`) → `rm` + `scp` new `/home/root/diary` →
  run shot hooks → `systemctl start diary.service`. Rebuild armv7 via the toltec
  docker toolchain (`./build.sh`).

## Out of scope (YAGNI)

- Precise non-rectangular (point-in-polygon) selection — the lasso's bounding
  rectangle is sufficient since the loop ink is erased before capture.
- Keeping the idle-whole-page trigger as an optional fallback — removed outright
  per the interaction model; can be revisited if the circle trigger proves
  insufficient.
- Stylus-button-based lasso — the basic rM2 Marker has no usable side button.
