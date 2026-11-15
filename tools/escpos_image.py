#!/usr/bin/env python3
"""Reference implementation: photo -> ESC/POS raster bytes (GS v 0).

This is the algorithm the Flutter app will port to Dart. Used to validate
the protocol on real hardware before writing app code.

  python3 tools/escpos_image.py photo.jpg --width 384 -o out.bin     # MP583 (58mm)
  python3 tools/escpos_image.py photo.jpg --width 576 --cut -o out.bin  # HZ-8360 (80mm)
  python3 tools/escpos_image.py photo.jpg --width 384 --device /dev/usb/lp0
"""
import argparse
import sys
import time

from PIL import Image, ImageEnhance, ImageOps

ESC, GS = 0x1B, 0x1D


def to_bitmap(path, width, dither=True, contrast=1.0, brightness=1.0):
    img = Image.open(path)
    img = ImageOps.exif_transpose(img).convert("L")
    h = round(img.height * width / img.width)
    img = img.resize((width, h), Image.LANCZOS)
    if brightness != 1.0:
        img = ImageEnhance.Brightness(img).enhance(brightness)
    if contrast != 1.0:
        img = ImageEnhance.Contrast(img).enhance(contrast)
    # Floyd-Steinberg via Pillow; threshold otherwise.
    return img.convert("1", dither=Image.FLOYDSTEINBERG if dither else Image.NONE)


def raster_bytes(bw, band_height=255):
    """Encode a 1-bit image as a sequence of GS v 0 bands.

    The 80mm manual caps yL+yH*256 at 4095 lines; mobile printers have small
    buffers (MP583: 40K per bitmap), so we send short bands.
    """
    w, h = bw.size
    bpl = (w + 7) // 8
    px = bw.load()
    out = bytearray()
    for y0 in range(0, h, band_height):
        bh = min(band_height, h - y0)
        out += bytes([GS, 0x76, 0x30, 0x00, bpl & 0xFF, bpl >> 8, bh & 0xFF, bh >> 8])
        for y in range(y0, y0 + bh):
            for xb in range(bpl):
                byte = 0
                for bit in range(8):
                    x = xb * 8 + bit
                    if x < w and px[x, y] == 0:  # black pixel -> burn dot
                        byte |= 0x80 >> bit
                out.append(byte)
    return bytes(out)


def build_job(path, width, cut, dither, contrast, brightness, band):
    bw = to_bitmap(path, width, dither, contrast, brightness)
    job = bytearray([ESC, 0x40])            # ESC @ init
    job += bytes([ESC, 0x61, 0x01])         # ESC a 1 center
    job += raster_bytes(bw, band)
    job += bytes([ESC, 0x64, 0x04])         # ESC d 4 feed 4 lines
    if cut:
        job += bytes([GS, 0x56, 0x42, 0x00])  # GS V B 0 feed+partial cut
    return bytes(job)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("image")
    ap.add_argument("--width", type=int, default=384, help="dots: 384 (58mm) or 576 (80mm)")
    ap.add_argument("--cut", action="store_true")
    ap.add_argument("--no-dither", action="store_true")
    ap.add_argument("--contrast", type=float, default=1.0)
    ap.add_argument("--brightness", type=float, default=1.0)
    ap.add_argument("--band", type=int, default=255, help="lines per GS v 0 command")
    ap.add_argument("--chunk", type=int, default=4096, help="bytes per write")
    ap.add_argument("--delay", type=float, default=0.0, help="seconds between chunks")
    ap.add_argument("-o", "--output")
    ap.add_argument("--device", help="e.g. /dev/usb/lp0 or /dev/ttyACM0")
    a = ap.parse_args()

    job = build_job(a.image, a.width, a.cut, not a.no_dither, a.contrast, a.brightness, a.band)
    print(f"{len(job)} bytes", file=sys.stderr)
    if a.output:
        open(a.output, "wb").write(job)
    if a.device:
        with open(a.device, "wb", buffering=0) as f:
            for i in range(0, len(job), a.chunk):
                f.write(job[i:i + a.chunk])
                if a.delay:
                    time.sleep(a.delay)


if __name__ == "__main__":
    main()
