#!/usr/bin/env python3
"""Tiny ESC/POS emulator: render a print job (.bin) to a PNG of the paper.

Understands what our tools and app emit: ESC @, ESC a, ESC d, ESC J, ESC !,
ESC E, ESC 3/2, ESC 7, DC2 #, GS V, GS v 0 (m 0..3), ESC * (0/1/32/33),
text + LF. Unknown commands are reported and skipped (best effort).

  python3 tools/escpos_render.py job.bin --width 576 -o paper.png
"""
import argparse
import sys

from PIL import Image, ImageDraw, ImageFont

ARGS = {  # ESC x -> number of parameter bytes (for skipping)
    0x40: 0, 0x61: 1, 0x64: 1, 0x4A: 1, 0x21: 1, 0x45: 1, 0x33: 1, 0x32: 0, 0x37: 3, 0x42: 2,
    0x2D: 1, 0x47: 1, 0x4D: 1, 0x56: 1, 0x7B: 1, 0x74: 1, 0x52: 1, 0x20: 1, 0x24: 2, 0x5C: 2, 0x76: 0,
    0x70: 3, 0x63: 2,
}


class Paper:
    def __init__(self, width):
        self.w = width
        self.rows = []  # list of bytearray rows (1 = black), each width w
        self.align = 0
        self.line_h = 30
        self.text_buf = ""
        self.big = False
        self.notes = []
        try:
            self.font = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf", 20)
        except OSError:
            self.font = ImageFont.load_default()

    def blank(self, n):
        for _ in range(n):
            self.rows.append(bytearray(self.w))

    def place(self, img_rows, img_w, scale_x=1, scale_y=1):
        ow = img_w * scale_x
        off = {0: 0, 1: max(0, (self.w - ow) // 2), 2: max(0, self.w - ow)}[self.align]
        for r in img_rows:
            row = bytearray(self.w)
            for x in range(img_w):
                if r[x]:
                    for sx in range(scale_x):
                        px = off + x * scale_x + sx
                        if px < self.w:
                            row[px] = 1
            for _ in range(scale_y):
                self.rows.append(bytearray(row))

    def flush_text(self):
        if not self.text_buf:
            return
        size = 40 if self.big else 24
        im = Image.new("1", (self.w, size + 6), 1)
        d = ImageDraw.Draw(im)
        tw = d.textlength(self.text_buf, font=self.font)
        x = {0: 0, 1: (self.w - tw) / 2, 2: self.w - tw}[self.align]
        d.text((x, 2), self.text_buf, font=self.font, fill=0)
        px = im.load()
        for y in range(im.height):
            self.rows.append(bytearray(1 if px[x2, y] == 0 else 0 for x2 in range(self.w)))
        self.text_buf = ""

    def image(self):
        h = max(1, len(self.rows))
        im = Image.new("L", (self.w, h), 250)
        px = im.load()
        for y, r in enumerate(self.rows):
            for x in range(self.w):
                if r[x]:
                    px[x, y] = 25
        return im


def render(data, width):
    p = Paper(width)
    i = 0
    n = len(data)
    while i < n:
        b = data[i]
        if b == 0x0A:
            if p.text_buf:
                p.flush_text()
            else:
                p.blank(p.line_h)
            i += 1
        elif b == 0x1B and i + 1 < n:
            c = data[i + 1]
            if c == 0x40:
                p.align, p.big, p.line_h = 0, False, 30
            elif c == 0x61:
                p.align = data[i + 2] % 48 if data[i + 2] >= 48 else data[i + 2]
            elif c == 0x64:
                p.flush_text()
                p.blank(data[i + 2] * p.line_h)
            elif c == 0x4A:
                p.flush_text()
                p.blank(data[i + 2])
            elif c == 0x21:
                p.big = bool(data[i + 2] & 0x30)
            elif c == 0x33:
                p.line_h = data[i + 2]
            elif c == 0x32:
                p.line_h = 30
            elif c == 0x2A:  # ESC * m nL nH
                m, cols = data[i + 2], data[i + 3] | data[i + 4] << 8
                k = 3 if m in (32, 33) else 1
                rows = [bytearray(cols) for _ in range(8 * k)]
                pos = i + 5
                for x in range(cols):
                    for kk in range(k):
                        byte = data[pos]
                        pos += 1
                        for bit in range(8):
                            if byte & (0x80 >> bit):
                                rows[kk * 8 + bit][x] = 1
                sx = 1 if m in (1, 33) else 2
                sy = 1 if m in (32, 33) else 3
                p.place(rows, cols, sx, sy)
                # ESC * leaves the print position on the line; the following LF advances
                if i := pos:
                    if pos < n and data[pos] == 0x0A:
                        pos += 1
                i = pos
                continue
            if c in ARGS:
                i += 2 + ARGS[c]
            else:
                p.notes.append(f"unknown ESC 0x{c:02x} at {i}")
                i += 2
        elif b == 0x1D and i + 1 < n:
            c = data[i + 1]
            if c == 0x76 and data[i + 2] in (0x30, 0):
                m = data[i + 3] % 48 if data[i + 3] >= 48 else data[i + 3]
                xb = data[i + 4] | data[i + 5] << 8
                yh = data[i + 6] | data[i + 7] << 8
                pos = i + 8
                rows = []
                for _ in range(yh):
                    r = bytearray(xb * 8)
                    for xx in range(xb):
                        byte = data[pos + xx]
                        for bit in range(8):
                            if byte & (0x80 >> bit):
                                r[xx * 8 + bit] = 1
                    rows.append(r)
                    pos += xb
                if xb * 8 > p.w:
                    p.notes.append(f"raster {xb * 8} dots wider than paper {p.w} (clipped)")
                p.place(rows, xb * 8, 2 if m in (1, 3) else 1, 2 if m in (2, 3) else 1)
                i = pos
            elif c == 0x56:
                p.flush_text()
                mode = data[i + 2]
                if mode in (0x41, 0x42, 65, 66):
                    p.blank(data[i + 3])
                    i += 4
                else:
                    i += 3
                p.rows.append(bytearray([1 if (x // 6) % 2 == 0 else 0 for x in range(p.w)]))  # cut mark
            elif c in (0x21, 0x42, 0x48, 0x66, 0x68, 0x77, 0x61, 0x72, 0x49):
                i += 3
            else:
                p.notes.append(f"unknown GS 0x{c:02x} at {i}")
                i += 2
        elif b == 0x12 and i + 1 < n and data[i + 1] == 0x23:  # DC2 # n
            i += 3
        elif b == 0x10 and i + 1 < n and data[i + 1] == 0x04:  # DLE EOT n
            i += 3
        elif b == 0x1F:  # ZJ proprietary US ...
            i += 3
        elif 32 <= b < 127:
            p.text_buf += chr(b)
            i += 1
        else:
            i += 1
    p.flush_text()
    return p


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("job")
    ap.add_argument("--width", type=int, default=384)
    ap.add_argument("-o", "--output", required=True)
    a = ap.parse_args()
    p = render(open(a.job, "rb").read(), a.width)
    p.image().save(a.output)
    for note in p.notes[:20]:
        print("note:", note, file=sys.stderr)
    print(f"{a.output}: {p.w}x{len(p.rows)}", file=sys.stderr)


if __name__ == "__main__":
    main()
