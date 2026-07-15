# reMarkable takeover diary — scroll, zoom & Figtree answers

**Date:** 2026-07-08
**Status:** Design approved, pending spec review
**Component:** on-device takeover app `remarkable-diary/takeover/diary.c` (rm2fb, OS 3.22). The in-cluster injection diary is **out of scope**.

## Problem

The takeover diary renders every answer *directly into the framebuffer at fixed device
coordinates*, and `render_text_block` stops drawing once it runs past the bottom of the
screen (`if(ay>(int)vinfo.yres-40)break;`). A long answer — or a large markmap / table /
flowchart — is **silently cut off with no way to see the rest**. There is no viewport and
no scroll; the app only reads the **pen** (`/dev/input/event1`) and never opens the
capacitive **touchscreen** (`/dev/input/event2`), so finger gestures do nothing. The
result reads as "frozen."

Separately, all text renders in a cursive font (Dancing Script). The user wants responses
in **Figtree** instead.

## Goals

1. **Figtree responses** — replace the cursive answer font with Figtree.
2. **Scroll** — pan a window over content taller than the screen, via one-finger swipe.
3. **Zoom** — `[+] [−] [↺]` on-screen buttons, crisp at any zoom level.
4. Nothing above breaks live pen writing, model switching, save-to-library, or clear.

## Decisions (from brainstorming)

| Question | Decision |
|---|---|
| Front-end | Takeover C app `diary.c` only; injection diary untouched |
| Controls | One-finger swipe = scroll; `[+] [−] [↺]` buttons = zoom; pen = write |
| Zoom quality | **Hybrid** — bitmap canvas for scroll, vector **re-render** for zoom (crisp at all levels) |
| Zoom style | **Reflow** for text (re-wrap to screen width, vertical scroll only); **geometric** for diagrams/markmap/tables (scale whole drawing) |
| Writing while zoomed | Pen writes into the canvas through the current window mapping (inverse of `panY`+`zoom`) — annotate at any view; no snap-to-home |
| Font | Replace `diary-font.ttf` with Figtree Regular; keep old as `diary-cursive.ttf` for revert |

## Architecture

### Mental model: page canvas + movable window

Introduce a logical **page canvas** larger than the screen. Both the user's handwriting
and the rendered answer live on the canvas. The screen is a **movable, zoomable window**
onto it.

```
   ┌─ canvas (RGB565, width = xres, height ≈ 6× yres) ─┐
   │  model bar (row 0..MODEL_BAR_H, pinned in fb)     │
   │  ~~~ handwriting (pen ink) ~~~                     │
   │  Figtree answer line 1                            │◄─ window [panY .. panY+viewH)
   │  Figtree answer line 2                            │   present() blits window → fb
   │  ...                                              │   + [+][−][↺] overlay + upd()
   │  (content_bottom)                                 │
   │  ......... blank .........                        │
   └───────────────────────────────────────────────────┘
```

### Retarget the pixel primitives

Today `px()` and the fillers write to the mmap'd framebuffer `fb`. Change them to write
into an offscreen `canvas` buffer (device-coordinate rendering, but in canvas space). All
render functions (`render_text_block`, `render_flow`, `render_markmap`, `render_table`,
`render_stats`, `render_diagram`) funnel through `px`/`disk`/`lineT`/`draw_glyph`, so they
inherit scroll/zoom with no per-function rewrite. Remove `render_text_block`'s
cut-off-at-bottom guard; it now draws the whole answer into the canvas.

State:
- `uint16_t* canvas;` `int canvas_w = xres, canvas_h ≈ 6*yres;`
- `int panY;` — top of the window in canvas rows (0 ≤ panY ≤ max(0, content_bottom − viewH))
- `float zoom;` — discrete steps {0.75, 1.0, 1.25, 1.5, 2.0, 3.0}, default 1.0
- `int content_bottom;` — max canvas row drawn (bounds scroll)
- `int viewH = yres − MODEL_BAR_H;` — model bar stays pinned in fb, not scrolled

### Compositor: `present()`

Blit the visible window from canvas → fb below the pinned model bar, draw the zoom-button
overlay on top, and issue **one** clamped `upd()` (GC16 on settle). The existing in-screen
clamp in `upd()` (the rm2fb crash guard) is preserved unchanged.

### Scroll — finger swipe (`event2`)

Open `/dev/input/event2` and poll it alongside the pen (`poll` on both fds). Track
`ABS_MT_POSITION_Y` + `BTN_TOUCH`; a one-finger vertical drag accumulates into `panY`
(clamped). Use a fast waveform during the drag and GC16 on release to clear ghosting.
Moves under a tap threshold are ignored for scroll (so button taps aren't eaten).

### Zoom — buttons + vector re-render

- Draw `[+] [−] [↺]` pinned bottom-right, on top of the composited window, hit-tested
  **before** ink/scroll so taps there never draw. Both pen tap and finger tap work.
- **Cache the last content**: the parsed `cJSON` spec (or plain text) + its `kind` +
  `startY`. On `[+]`/`[−]`: change `zoom`, clear the canvas, re-invoke the matching render
  with layout scaled by `zoom`, then `present()`. Anchor to the current top-of-view
  (rescale `panY` by the zoom ratio). `[↺]` → `zoom=1.0, panY=0`.
- **Reflow text**: multiply the font pixel size and line height by `zoom`, keep wrap width
  = screen width ⇒ text grows and re-wraps, only vertical scroll.
- **Geometric diagrams**: scale the render's internal coordinate mapping by `zoom` ⇒ the
  whole drawing scales; pan covers overflow.
- Re-render is vector, so glyphs and lines are crisp at every zoom step.

### Writing while zoomed/scrolled

On pen contact, map device pen coords → screen → **canvas** coords via the inverse of
(`panY`, `zoom`), then draw the stroke into the canvas. Blit just that stroke's window
region to fb with the fast (A2) waveform for low-latency ink, as today. Answers still
render below the handwriting's canvas bbox. No snap-to-home.

### Preserved behavior

- **Animated word reveal** stays: words render into the canvas, then each word's region is
  blitted to fb in sequence (only while inside the window). Re-render on zoom is instant
  (no animation).
- **Model bar** pinned at fb top; not part of the scrollable canvas.
- **Save-to-library** now snapshots the **full canvas content** (row 0..`content_bottom`),
  so the saved PDF contains the entire answer, not just the cropped screen.
- **Clear** (flip-to-eraser + tap) resets canvas to white, `panY=0`, `zoom=1.0`,
  `content_bottom=0`.

### Figtree font

Ship Figtree Regular to `/home/root/diary-font.ttf` (the current `FONT_PATH`); copy the old
cursive to `/home/root/diary-cursive.ttf` for revert. No code change beyond confirming the
path. All text — answers, model-bar labels, diagram labels — becomes Figtree. (The Roboto
Mono metric font at `MONO_PATH` for stats tiles is unchanged.)

## Error handling & edge cases

- **Canvas allocation failure** → log and fall back to today's direct-to-`fb` rendering
  (no scroll/zoom), so the app still works on low memory.
- `panY` and `zoom` are bounds-clamped; scrolling never exceeds `content_bottom`.
- Content taller than the canvas (rare, very long answers) clamps `content_bottom` to
  `canvas_h`; log a truncation notice (no silent cut).
- All `upd()` regions remain in-screen-clamped (rm2fb crashes on out-of-bounds regions).
- Zoom re-render requires a cached spec; if the last output was a fallback plain-text with
  no cache, `[+]`/`[−]` re-wrap the stored text string.

## Testing

Use the existing `DESK_DEMO=<file>` harness (renders a spec, dumps
`/home/root/demo-out.png`, then `pause()`s):

1. **Overflow**: feed a text answer > 2 screens tall; assert it renders fully into the
   canvas (`content_bottom` > `viewH`) with no cut-off.
2. **Scroll**: dump `present()` output at `panY=0` and a scrolled offset; confirm different
   content regions appear and bottom clamps correctly.
3. **Zoom-in (text)**: at `zoom=2.0`, confirm glyphs are ~2× and text re-wrapped (crisp,
   from re-render — not upscaled bitmap).
4. **Zoom (diagram)**: a markmap/flow at `zoom=2.0` scales geometrically and pans.
5. **Save**: after a long answer, save-to-library and confirm the PDF contains the full
   canvas, not the screen crop.
6. **Regression**: model switch, clear, and live pen ink still behave as before at
   `zoom=1.0, panY=0`.

Physical on-device verification (a human writes, then swipes/zooms) is the final gate,
since touch-gesture feel and e-ink ghosting can't be judged from a PNG dump.

## Out of scope (YAGNI)

- Pinch-to-zoom (buttons chosen instead).
- Horizontal scroll for text (reflow avoids it).
- Two-finger / momentum / fling scrolling.
- Changes to the in-cluster injection diary.
- Per-notebook zoom persistence.
