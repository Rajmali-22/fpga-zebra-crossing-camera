#!/usr/bin/env python3
"""
Render the 8x16 bitmap font used by the VGA overlay (rtl/io/vga_overlay.v)
into mem/font8x16.mem: 128 characters x 16 rows, one byte per row, bit 7 =
leftmost pixel. Also writes docs/font_preview.png to check it by eye.

    python python/make_font.py [--ttf C:/Windows/Fonts/consolab.ttf]
"""

import argparse
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parent.parent


def render(ttf, size):
    font = ImageFont.truetype(ttf, size)
    rows = np.zeros((128, 16), np.uint8)
    for c in range(32, 127):
        img = Image.new("L", (8, 16), 0)
        d = ImageDraw.Draw(img)
        l, t, r, b = d.textbbox((0, 0), chr(c), font=font)
        # centre horizontally, baseline so that capitals sit in rows 2..13
        asc = font.getmetrics()[0]
        d.text(((8 - (r - l)) / 2 - l, 13 - asc), chr(c), font=font, fill=255)
        bits = (np.asarray(img) >= 110).astype(np.uint8)
        rows[c] = np.packbits(bits, axis=1)[:, 0]
    return rows


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--ttf", default=r"C:\Windows\Fonts\consolab.ttf")
    p.add_argument("--size", type=int, default=14)
    a = p.parse_args()
    rows = render(a.ttf, a.size)
    (ROOT / "mem" / "font8x16.mem").write_text("\n".join(f"{v:02x}" for v in rows.reshape(-1)) + "\n")
    text = ["ZEBRA CROSSING! NOT SURE", "NO CROSSING WAITING CAMERA", "S503 M+026 13FPS PHOTO PAUSED"]
    canvas = np.zeros((16 * len(text), 8 * max(map(len, text))), np.uint8)
    for li, line in enumerate(text):
        for ci, ch in enumerate(line):
            bits = np.unpackbits(rows[ord(ch)][:, None], axis=1)
            canvas[li * 16:(li + 1) * 16, ci * 8:(ci + 1) * 8] = bits * 255
    (ROOT / "docs").mkdir(exist_ok=True)
    Image.fromarray(canvas).resize((canvas.shape[1] * 4, canvas.shape[0] * 4), Image.NEAREST) \
        .save(ROOT / "docs" / "font_preview.png")
    print("wrote mem/font8x16.mem and docs/font_preview.png")


if __name__ == "__main__":
    main()
