# reMarkable 2 — 4 dots/inch paper

Light gray **dot grid** sized for the **reMarkable 2** panel (1404×1872).

| Spec | Value |
|------|--------|
| Density | **4 dots per inch** (¼″ / 6.35 mm pitch) |
| Device | reMarkable 2 (~227 ppi) |
| Dot color | light gray `#B4B4B4` on white |

## Files (`out/`)

| File | Use |
|------|-----|
| `dots-4dpi-rm2-50p.pdf` | **Import as a notebook** (50 blank pages) — easiest |
| `dots-4dpi-rm2.pdf` | Single page PDF |
| `dots-4dpi-rm2.png` | Native template PNG (SSH / custom template) |

## Import (recommended)

1. Open **reMarkable desktop** (or mobile app).
2. Drag in `out/dots-4dpi-rm2-50p.pdf`.
3. Sync to the tablet — use it like any notebook.

## Regenerate

```bash
cd paper
python3 generate_dot_paper.py              # 4 dpi, 50 pages
python3 generate_dot_paper.py --dpi 5      # denser
python3 generate_dot_paper.py --pages 100  # longer notebook
```

Requires Python 3 + Pillow (`pip install pillow`).
