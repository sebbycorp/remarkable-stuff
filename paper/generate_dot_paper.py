#!/usr/bin/env python3
"""Generate reMarkable 2 dot-grid paper at 4 dots per inch.

Outputs:
  - PNG at native rM2 resolution (custom template)
  - Multi-page PDF (import as a notebook)

Physical spacing: 1/4 inch between dots (4 dpi).
Dot color is light gray so ink stays readable on e-ink.
"""

from __future__ import annotations

import argparse
import math
from pathlib import Path

from PIL import Image, ImageDraw

# reMarkable 2 panel
RM2_W = 1404
RM2_H = 1872
RM2_DIAG_IN = 10.3

# ~227 ppi → 4 dots/inch ≈ 56.8 px pitch
RM2_PPI = math.hypot(RM2_W, RM2_H) / RM2_DIAG_IN
RM2_WIDTH_IN = RM2_W / RM2_PPI
RM2_HEIGHT_IN = RM2_H / RM2_PPI

# Light gray dots (good on e-ink; not too loud under pen)
DOT_RGB = (180, 180, 180)
BG_RGB = (255, 255, 255)


def draw_dot_grid(
    width: int,
    height: int,
    dots_per_inch: float,
    ppi: float,
    *,
    margin_in: float = 0.0,
    dot_radius_px: float | None = None,
) -> Image.Image:
    """Return a RGB image with a centered dot grid."""
    img = Image.new("RGB", (width, height), BG_RGB)
    draw = ImageDraw.Draw(img)

    spacing = ppi / dots_per_inch
    if dot_radius_px is None:
        # ~0.45 mm on rM2 — visible but quiet
        dot_radius_px = max(1.0, ppi * 0.018)

    margin_px = margin_in * ppi
    usable_w = width - 2 * margin_px
    usable_h = height - 2 * margin_px

    cols = int(usable_w / spacing) + 1
    rows = int(usable_h / spacing) + 1

    # Center the lattice in the usable area so edge margins are even
    grid_w = (cols - 1) * spacing
    grid_h = (rows - 1) * spacing
    x0 = margin_px + (usable_w - grid_w) / 2
    y0 = margin_px + (usable_h - grid_h) / 2

    r = dot_radius_px
    for row in range(rows):
        y = y0 + row * spacing
        for col in range(cols):
            x = x0 + col * spacing
            draw.ellipse((x - r, y - r, x + r, y + r), fill=DOT_RGB)

    return img


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--dpi",
        type=float,
        default=4.0,
        help="Dots per inch (default: 4)",
    )
    parser.add_argument(
        "--pages",
        type=int,
        default=50,
        help="PDF page count for notebook import (default: 50)",
    )
    parser.add_argument(
        "--out-dir",
        type=Path,
        default=Path(__file__).resolve().parent / "out",
        help="Output directory",
    )
    args = parser.parse_args()

    out = args.out_dir
    out.mkdir(parents=True, exist_ok=True)

    stem = f"dots-{args.dpi:g}dpi-rm2"
    page = draw_dot_grid(RM2_W, RM2_H, args.dpi, RM2_PPI)

    png_path = out / f"{stem}.png"
    page.save(png_path, "PNG", optimize=True)

    # PDF: embed at true physical size so 4 dpi is correct when reMarkable
    # maps the page full-screen (width/height in inches via resolution).
    pdf_path = out / f"{stem}-{args.pages}p.pdf"
    pages = [page] * args.pages
    pages[0].save(
        pdf_path,
        "PDF",
        save_all=True,
        append_images=pages[1:],
        resolution=RM2_PPI,
    )

    # One-page PDF for quick single-template import
    one_path = out / f"{stem}.pdf"
    page.save(one_path, "PDF", resolution=RM2_PPI)

    print(f"reMarkable 2 panel: {RM2_W}×{RM2_H} px @ {RM2_PPI:.1f} ppi")
    print(f"Physical page:      {RM2_WIDTH_IN:.3f}\" × {RM2_HEIGHT_IN:.3f}\"")
    print(f"Dot pitch:          {1 / args.dpi:.3f}\" ({RM2_PPI / args.dpi:.1f} px)")
    print(f"Wrote {png_path}")
    print(f"Wrote {one_path}")
    print(f"Wrote {pdf_path} ({args.pages} pages)")


if __name__ == "__main__":
    main()
