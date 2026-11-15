#!/usr/bin/env python3
"""Overlay a rendered receipt (red) on a photo of a real receipt (grey),
scaled to printer dots, to check a template's layout 1:1.

  python3 tools/overlay_compare.py photo.png render.png -o overlay.png \\
      --paper-x 14 267.5 --paper-mm 80 \\
      --anchor-photo-y 219.5 --anchor-render-y 298 --content-x 20

--paper-x      left/right paper edge in the photo (px)
--paper-mm     paper width (80 mm = 640 dots at 203 dpi)
--anchor-*     a line that must coincide: its y in the photo (px) and in the
               render (dots), e.g. the cap top of a distinctive text line
--content-x    where the original's content starts, in dots from the paper edge
Writes the full overlay plus 500-row slices (<output>_0.png, _1.png, ...).
"""
import argparse

from PIL import Image, ImageOps


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("photo")
    ap.add_argument("render")
    ap.add_argument("-o", "--output", required=True)
    ap.add_argument("--paper-x", type=float, nargs=2, required=True)
    ap.add_argument("--paper-mm", type=float, default=80)
    ap.add_argument("--anchor-photo-y", type=float, required=True)
    ap.add_argument("--anchor-render-y", type=int, required=True)
    ap.add_argument("--content-x", type=int, default=0)
    a = ap.parse_args()

    left, right = a.paper_x
    k = a.paper_mm * 8 / (right - left)  # dots per photo pixel
    photo = Image.open(a.photo).convert("L")
    crop = photo.crop((round(left), 0, round(right), photo.height))
    p = ImageOps.autocontrast(crop.resize((round(crop.width * k), round(crop.height * k)), Image.LANCZOS))
    ours = Image.open(a.render).convert("L")
    dy = round(a.anchor_photo_y * k) - a.anchor_render_y

    over = Image.merge("RGB", (p, p, p))
    op, o = over.load(), ours.load()
    for y in range(ours.height):
        ty = y + dy
        if not 0 <= ty < over.height:
            continue
        for x in range(ours.width):
            tx = x + a.content_x
            if o[x, y] < 128 and 0 <= tx < over.width:
                op[tx, ty] = (230, 0, 0)
    top = max(0, dy)
    over = over.crop((0, top, over.width, min(over.height, dy + ours.height)))
    over.save(a.output)
    stem = a.output.rsplit(".", 1)[0]
    for i, y0 in enumerate(range(0, over.height, 500)):
        over.crop((0, y0, over.width, min(over.height, y0 + 500))).save(f"{stem}_{i}.png")
    print(f"{a.output}: {over.size}, {k:.3f} dots/px, dy={dy}")


if __name__ == "__main__":
    main()
