# Receipt editor

The **Receipt** tab (next to **Photo**) builds receipts, notes and labels from
blocks and prints them through the same printer selection, transports,
chunking, darkness, cut and copies settings as the photo tab.

Everything is **rasterised by the app** to a 1-bit bitmap at the printer's dot
width (384 dots for 58 mm, 576 dots for 80 mm) and sent as `GS v 0` raster
bands. The printer's own fonts and code pages are never used, so the preview is
exactly what prints, and umlauts, €, ß, ✓, ☐, Greek, Cyrillic… all work (the
printers' code page support is unknown).

## Features

- Block list: add, duplicate, delete, drag to reorder; tap a block to open its
  property panel.
- Live paper preview at the selected printer width, with cut / tear-off
  markers, size info and warnings (invalid barcode data, QR too long…).
  Toggle *Actual dots* for 1 dot = 1 pixel.
- Undo / redo (toolbar, Ctrl+Z / Ctrl+Y / Ctrl+Shift+Z); typing and slider
  drags coalesce into one step.
- Templates: three built-in samples (shop receipt, to-do note, price label),
  save to / open from a list on this device (shared_preferences), import and
  export `.json` files. The current receipt is auto-saved as a draft.
- Placeholder tokens, expanded when rendering:

  | Token | Result |
  |---|---|
  | `{date}` / `{time}` / `{datetime}` | `2026-11-15` / `14:05` / `2026-11-15 14:05` |
  | `{date:dd.MM.yyyy HH:mm:ss}` | custom pattern (`yyyy yy MM dd HH mm ss`) |
  | `{n}` / `{n:0000}` | running number, optionally zero-padded |
  | `{{` | literal `{` |

  `{n}` starts at the receipt's *Next number* (Receipt settings) and advances
  by one per printed copy, so 3 copies print 7, 8, 9.

Wide windows show editor and preview side by side; narrow ones (phones) use
*Edit* / *Preview* tabs.

## Block types

| Block | Properties |
|---|---|
| Text | multi-line text, align L/C/R, font (Sans / Mono), size in dots, bold, underline, wide ×1–4, tall ×1–4, white-on-black |
| Columns | 2 or 3 cells with relative widths and own alignment, optional dot leaders (`Coffee ........ 3.20`), shared text format |
| Separator | solid, dashed, dotted, double or blank space; thickness and block height in dots |
| Image | picture file (EXIF-rotated, shrunk to ≤ 1152 px wide when stored), width % of paper, align, the photo tab's dithering / brightness / contrast / gamma / threshold / invert / rotate |
| QR code | data, module size in dots, error correction L/M/Q/H, align |
| Barcode | Code 128, EAN-13, EAN-8, UPC-A, Code 39; bar (module) width, height, human-readable text, align. EAN/UPC check digits are added automatically |
| Feed | blank paper in mm |
| Cut | cuts the paper (`GS V B 48`) on printers with a cutter; feeds for tearing off on printers without |

QR codes, barcodes and separators are drawn on whole dots; QR and barcode
modules shrink automatically if the code would be wider than the paper.

## Rendering pipeline

```
Receipt (blocks)
  │  per block → layout piece of known height (lib/receipt/renderer.dart)
  │    text / columns / barcode label  → dart:ui Paragraph on a Canvas (vector)
  │    image                           → decodePhoto + convertPhoto (dithered MonoBitmap, cached)
  │    QR / barcode bars / separators  → set directly in the MonoBitmap
  │    feed                            → blank rows (mm × 8)
  │    cut                             → starts a new segment
  ▼
per segment: vector pieces recorded with PictureRecorder, read back in
2048-row tiles (toImage → rawRgba) and thresholded (no dithering, so text
stays crisp; anti-aliased pixels darker than 160/255 become dots), then the
bitmap pieces are blitted on top
  ▼
RenderedReceipt { width, segments: [MonoBitmap…], endsWithCut, warnings }
  ▼  lib/receipt/encode.dart  buildReceiptJob(copies, profile, JobOptions)
ESC @ · density (if set) · for each copy: GS v 0 bands per segment,
GS V B 48 (or ESC d n) between segments, final cut/feed per job options
  ▼
PrinterController.send → sendChunked over the selected transport
```

- Text uses the bundled DejaVu Sans / DejaVu Sans Mono (regular + bold,
  `app/assets/fonts`, Bitstream Vera license) so output is identical on every
  platform; characters they lack fall back to system fonts.
- Empty segments (leading cut, two cuts in a row, trailing cut) are dropped;
  a trailing Cut block forces a final cut even if *Cut after printing* is off.
- Each copy is rendered separately so `{n}` can differ per copy.
- Rendering runs on the UI isolate (dart:ui); image decoding/dithering runs in
  `compute`. Works on all platforms including web — no `dart:io`.

Code: `app/lib/receipt/` (model, tokens, codes, renderer, encode, editor
state, templates — no widgets) and `app/lib/ui/receipt/` (page and property
panels). The printer state and send path shared by both tabs live in
`app/lib/ui/printer_controller.dart`.

## JSON format

```json
{
  "format": "thermal_photo.receipt",
  "version": 1,
  "name": "Shop receipt",
  "counter": 1,
  "blocks": [
    {"type": "text", "text": "CORNER CAFÉ", "align": "center",
     "font": "sans", "size": 30, "bold": true, "underline": false,
     "scaleX": 1, "scaleY": 2, "invert": false},
    {"type": "columns", "fill": true,
     "cells": [{"text": "Cappuccino", "align": "left", "flex": 3},
               {"text": "3.20", "align": "right", "flex": 1}],
     "font": "mono", "size": 22, "bold": false, "underline": false, "scaleX": 1, "scaleY": 1},
    {"type": "separator", "style": "dashed", "thickness": 2, "height": 16},
    {"type": "image", "name": "logo.png", "width": 60, "align": "center",
     "dither": "atkinson", "brightness": 0.0, "contrast": 1.0, "gamma": 1.3,
     "threshold": 128, "invert": false, "rotate90": false, "data": "<base64 PNG/JPEG>"},
    {"type": "qr", "data": "https://example.com/?r={n}", "module": 5, "ecc": "medium", "align": "center"},
    {"type": "barcode", "symbology": "ean13", "data": "400638133393",
     "module": 2, "height": 80, "text": true, "align": "center"},
    {"type": "feed", "mm": 5},
    {"type": "cut"}
  ]
}
```

| Field | Values |
|---|---|
| `align` | `left`, `center`, `right` |
| `font` | `sans`, `mono` |
| `size`, `thickness`, `height`, `module` | printer dots (8 dots = 1 mm) |
| `style` | `solid`, `dashed`, `dotted`, `double`, `blank` |
| `ecc` | `low`, `medium`, `quartile`, `high` |
| `symbology` | `code128`, `ean13`, `ean8`, `upcA`, `code39` |
| `dither` | `atkinson`, `floydSteinberg`, `ordered`, `threshold` |

Reading is tolerant: missing fields take defaults, out-of-range values are
clamped, unknown block types (from a newer version) are skipped. A file with a
different `format` tag, or without a `blocks` list, is rejected. Saved receipts
on the device are stored as one JSON array of these objects (key
`receipt.saved`); on the web that is browser localStorage, so keep embedded
images small.

## Tests

- `app/test/receipt_test.dart` — JSON round-trip of every block type and the
  templates, tolerant reading, tokens, barcode/QR module patterns, editor
  undo/redo/reorder, job encoding (cuts between segments, 48/72 bytes per row,
  darkness, copies), renderer (segment widths, cut splitting, exact feed /
  separator heights, alignment, QR finder pattern, barcode width, image
  dithering).
- `app/integration_test/app_test.dart` — drives the real Linux app: switches
  to the HZ-8360 profile, opens the price-label sample, adds a text block after
  its cut, prints to the dump transport and checks two `GS V B` cuts and
  72-byte raster rows; then undo/redo between templates and prints the shop
  receipt. Copies of the jobs are written next to the dump file
  (`<dump>.label.bin`, `<dump>.shop.bin`):

  ```sh
  THERMAL_PHOTO_DUMP=/tmp/job.bin flutter test integration_test -d linux
  python3 ../tools/escpos_render.py /tmp/job.bin.shop.bin --width 576 -o /tmp/shop.png
  ```

  The rendered jobs' QR code, Code 128 and EAN-13 were checked with a
  barcode reader (zxing-cpp).
