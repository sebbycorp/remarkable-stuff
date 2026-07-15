# reMarkable diary — canvas v2 (hybrid pages + tall vector + touch + persist)

**Date:** 2026-07-10  
**Status:** ✅ Implemented (SebbyCorp Notepad takeover)  
**Extends:** `2026-07-10-remarkable-diary-canvas-design.md`  
**See also:** `2026-07-10-remarkable-sebbycorp-notepad-status.md` (shipped product matrix)

## Goal

Ship A+B+C+persistence as one coherent upgrade:

| Letter | Feature |
|---|---|
| A | Undo + manual **Ask** button |
| B | Finger pan / pinch-zoom (`event2`) |
| C | Hybrid multi-page + tall vector canvas per page |
| + | Persistent notebook on disk across restarts |

## Architecture

### Page model (source of truth)

Each of up to `MAXPAGES` pages holds:

- **Strokes** — vector points in canvas coords (`tool`, `style`, `width`, `erase` flag)
- **Viewport** — `scrollX`, `scrollY`, `scale` (default 0,0,1)
- **Answer bitmaps** — Phase-1 raster captures of AI output (viewport-sized), placed at canvas `(x,y)`

Canvas size per page: full width × `CANVAS_SCREENS` (3) content heights  
Content band on screen: `y ∈ [MODEL_BAR_H, yres − FOOTER_H)`

```
screen_x = (canvas_x − scrollX) * scale
screen_y = MODEL_BAR_H + (canvas_y − scrollY) * scale
```

Framebuffer page snapshots are **no longer** the source of truth. `page_show` → full **repaint** from the model.

### A — Undo + Ask

- Undo pops the last stroke on the current page and repaints (menu row **Undo**).
- Footer **Ask** captures the current content viewport → OCR → answer path (same as idle AI).
- Ask works even when `AI: off` (one-shot). Idle auto-ask still requires `AI: on`.
- After AI paints, capture content band into an answer bitmap at the current canvas viewport origin.

### B — Finger (`/dev/input/event2`)

- 1 finger drag → pan  
- 2 finger pinch → zoom about midpoint (scale clamped ~0.5…2.5)  
- Finger taps on chrome hit the same zones as pen  
- Pen only draws; fingers only navigate (no palm-rejection needed)

e-ink: A2 while panning; GC16 settle on finger-up.

### C — Hybrid pages

Keep `pg N/M`, `+`, delete. Each page is an independent tall canvas + viewport.

### Persistence

- Path: `/home/root/diary-nb/notebook.dnb`
- Magic `DNB1`, version, `npages`, `curpage`
- Per page: viewport + strokes (points inline)
- Answers: optional sibling PNGs `ans-p{N}-a{M}.png` + placement in the notebook header section
- Autosave: debounced after pen-up, on page change, undo, clear, home, exit

## Follow-ups shipped after v2

- UI polish: slim footer, tool chip, Settings layout, Delete page  
- Stamps: `/home/root/diary-stamps/`, 50×50 logo insert, move (finger/pen/menu mode)  
- Brand: SebbyCorp Notepad  
- Removed: manual Ask button, empty-state hint text  

## Still out of scope

- Phase-2 crisp vector re-render of markmaps at every zoom  
- Multi-notebook picker / cloud sync  
- Infinite 2D canvas / stamp resize UI  
