#!/usr/bin/env python3
"""Draws the car's number plate texture (assets/tex/plate.png). Needs Pillow.

The plate mesh is planar-mapped by tools/export_car.py: u runs left to right and v top to bottom across the
plate as seen from behind, so the image is drawn the way it reads.
"""
import os
from PIL import Image, ImageDraw, ImageFont

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
W, H = 1024, 292     # the plate mesh is 0.358 x 0.102 m


def main():
    im = Image.new("RGB", (W, H), (236, 237, 233))
    d = ImageDraw.Draw(im)
    d.rounded_rectangle([10, 10, W - 11, H - 11], radius=26, outline=(24, 24, 26), width=9)
    font = ImageFont.truetype(os.path.join(ROOT, "fonts", "Inter.ttf"), 190)
    try:
        font.set_variation_by_axes([600])
    except Exception:
        pass
    text = "CNCPT R1"
    x0, y0, x1, y1 = d.textbbox((0, 0), text, font=font)
    d.text(((W - (x1 - x0)) / 2 - x0, (H - (y1 - y0)) / 2 - y0), text, font=font, fill=(22, 22, 24))
    out = os.path.join(ROOT, "assets", "tex", "plate.png")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    im.save(out, optimize=True)
    print("wrote", out)


if __name__ == "__main__":
    main()
