# reMarkable diary — scrollable / zoomable writing canvas

**Date:** 2026-07-10
**Status:** Superseded / folded into canvas v2 — ✅ shipped as hybrid pages + tall vector + finger pan/zoom  
**See:** `2026-07-10-remarkable-diary-canvas-v2-design.md`, `2026-07-10-remarkable-sebbycorp-notepad-status.md`

## Goal

Turn the diary from a single fixed screen into a **tall, scrollable, zoomable canvas**:
write anywhere on a long roll of paper, **one-finger drag to scroll, two-finger pinch to
zoom**, with ink staying **crisp at any zoom** (vector redraw). This is the "use it as my
main app" ask — a real notebook surface, not one screen.

## Decisions (from brainstorming)

| Question | Decision |
|---|---|
| Zoom quality | **Crisp** — store content as data, repaint at the current zoom (vector) |
| Canvas shape | **Tall scroll** — 1 screen wide, several screens tall |
| Input split | **Pen = draw/write; finger = navigate** (1-finger pan, 2-finger pinch-zoom) |
| e-ink refresh | Fast partial paints during a gesture; one full refresh when it settles (de-ghost) |

## The core change: immediate-mode → model + repaint

Today the diary draws pen strokes straight to the framebuffer and forgets them, and each
answer renders once at a fixed spot. That cannot scroll or zoom. The new core:

1. **A content model in canvas coordinates** (canvas = 1404 wide × N×1872 tall):
   - **Strokes** — every pen stroke stored as a list of `(cx, cy)` points. Vector →
     crisp at any zoom.
   - **Answer objects** — each AI answer placed at a canvas `(x, y)` with its kind + data
     (text / markmap / table / …).
2. **A viewport** — `scrollY` (+ `scrollX` when zoomed) and `scale`. Screen = `(canvas −
   offset) × scale`.
3. **A repaint pass** — clear the content area, then draw every *visible* stroke and
   answer object transformed by the viewport. Runs on pan/zoom and after new content.

## Gestures (adds the touchscreen — `event2`)

- Pen unchanged: draw ink, corner taps (save / library / switch), idle → ask AI.
- Finger (new): **1 finger drag = pan**; **2 fingers = pinch-zoom** (scale about the pinch
  midpoint). Parse Type-B multitouch (slots, tracking-id, positions).
- **Calibration pass** (one deploy cycle): log raw touch coords, map to screen/canvas.
- Pen and finger are distinct devices, so "pen draws / finger navigates" is clean — no
  palm-rejection guesswork.

## Rendering the two content types at zoom

- **Strokes** — transform each point by the viewport and draw line segments. Always crisp.
- **Answers** — for crispness the renderers must draw at an arbitrary scale+offset, not
  the current "scale-to-fit one screen". Two-phase to keep this shippable:
  - **Phase 1 (this build):** strokes are fully vector/crisp on the canvas. Answers are
    rendered once into an offscreen bitmap placed at a canvas position; on zoom they
    scale like an image (crisp at 1×, mild softening when zoomed in). Delivers the whole
    scroll/zoom writing experience now.
  - **Phase 2 (follow-up):** make `render_text_block` / `render_markmap` / `render_table`
    viewport-aware so answers (especially big maps) re-render **sharp** at any zoom.
  This ordering gets you the canvas fast, then upgrades map sharpness without redesign.

## e-ink refresh strategy
- During a pan/zoom gesture: fast, low-quality partial updates (A2-style) for
  responsiveness; accept transient ghosting.
- On gesture end (finger up, ~150 ms settle): one full-region refresh (GC16) to clean up.
- Cap repaint cost: skip strokes fully outside the viewport; simplify (decimate) points
  when zoomed far out.

## Interaction details
- **Ask AI** captures the **current viewport** as the question image (what you see is what
  it reads); the answer object is placed just below the captured region in canvas space.
- New content auto-scrolls into view.
- A **"recenter / top"** affordance (corner tap) to jump back to the top if lost.
- Save-to-library / library-exit / model-switch corner taps unchanged.

## Risks & mitigations
- **Performance** — many strokes × repaint on a slow CPU/e-ink. Mitigate: viewport
  culling, point decimation at low zoom, partial-update during gestures.
- **Memory** — strokes stored as compact int point arrays; answer bitmaps freed when far
  off-view (re-render on return). Bounded canvas caps growth.
- **Coordinate/transform bugs** — the pen and touch transforms differ from screen; unit
  tests off-device for the math + a calibration pass on-device.
- **Ghosting** — the settle-time full refresh; a manual "refresh" corner tap as backstop.
- **Scope** — this is the largest change to `diary.c`; Phase 1/2 split keeps each shippable
  and testable.

## Testing
- Off-device: unit-test the viewport transform + culling (canvas↔screen round-trips).
- On-device calibration: log raw touch, map pan/pinch to canvas.
- Draw strokes across 3 screen-heights → scroll through them crisply; pinch-zoom in/out →
  strokes stay sharp, position holds under the pinch midpoint.
- Ask AI mid-canvas → answer lands below the question; scroll away and back → it persists.
- Reboot (watchdog) → diary returns (canvas resets to empty top — persistence is out of
  scope for now).

## Out of scope (YAGNI, for now)
- **Persisting the canvas across restarts** (strokes are in memory; a reboot starts fresh).
  Could add later (serialize strokes to /home).
- Phase-2 crisp answer re-render (separate follow-up as noted).
- Infinite/2D canvas (tall-scroll only).
- Multi-page/document management inside the diary (that's the reMarkable library).
