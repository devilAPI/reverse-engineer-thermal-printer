# Reverse-engineering log

Chronological lab notebook. Every step: what was done, exact commands, what came
out, and what it means. Findings are summarised in [RESEARCH.md](RESEARCH.md).

Vendor files (manual PDF, driver RAR) are **not** committed — they are
proprietary. Where to get them is noted so results can be reproduced.

---

## 2026-11-15 — Session 1: desk research before hardware arrives

### 1. Inventory of what we were given

| File | Size | Notes |
|---|---|---|
| `MP583-user manual （EN，Neutral) Type C -20211014.pdf` | 481 KB | ships with MP583 |
| `80MM Thermal Printer Driver & Tools -33.rar` | 42 MB | vendor kit for HZ-8360 |

### 2. MP583 user manual

Read all 8 pages. Surprise: the "MP583" is **not** an 80 mm printer but a
**58 mm mobile printer** ("MOBILE THERMAL PRINTER", Type-C model).

Key specs (manual ch. 2):
- Thermal line, 203 dpi (8 dots/mm), 70 mm/s
- Paper 58 mm, **printable 48 mm → 48 × 8 = 384 dots**
- Interfaces: Bluetooth + USB (Type-C)
- Fonts 9×17 / 12×24, 1D barcodes, QR
- **Graphics: max 40 KB per bitmap, 64 KB total** → images must be sent in bands
- Sensors: paper-out, low battery; 1500 mAh 7.4 V Li-ion
- SDK: Android/iOS; driver Win7/8/10

Operation (ch. 3):
- Bluetooth name **`MPT-II`**, PIN **`0000`**
- Self-test: hold FEED + press POWER ~2 s
- FEED button stops after 250 mm or at black mark

Conclusion: "MPT-II" naming points to the HPRT MPT-II firmware family (see §5).

### 3. Unpacking the 80 mm vendor kit

`7z` fails on this RAR5 ("Unsupported Method"), `unrar` works:

```sh
unrar x -o+ "80MM Thermal Printer Driver & Tools -33.rar"
```

Contents (abridged):
```
Printer Driver/  Linux (install58/install80 CUPS installers), Mac (.dmg), OPOS, Windows V11.3.0.3
Printer Manual/  80MM Printer Programmer Manual.pdf, Instruction Manual.pdf, WIFI config
Printer SDK/     Android (BlueTooth/USB/NET/WIFI demos), iOS PrinterDemo
Printer Tools/   IPrinter.exe, Printer_tools_V3.2.exe, Printer Setup Tools V1.0.9.exe
```

Java package names `cn.com.zj.*` → **Zijiang (ZJ)** reference design, the
generic Chinese ESC/POS platform behind dozens of brands.

### 4. Programmer manual → raster command

```sh
pdftotext -layout "80MM Printer Programmer Manual.pdf" prog.txt
grep -n 'GS v\|raster' prog.txt
```

`GS v 0` (p. 24):
```
1D 76 30 m xL xH yL yH d1…dk
m: 0/48 normal, 1/49 double-width, 2/50 double-height, 3/51 quadruple
x = bytes per row (1..128), y = rows (1..4095), k = x*y
bit=1 → dot printed, MSB = leftmost
```
Also present: `ESC *` (column bit image), `FS p`/`FS q` (NV logos, 192 KB),
`GS V` (cut). Note: 4095-row cap per command.

`(The Instruction Manual PDF is image-only; pdftotext gives 0 lines.)`

### 5. Android USB SDK — what does the vendor app actually send?

Decompiled the closed `usbsdk.jar` with `javap -c -p`:

```sh
unzip usbsdk.jar && javap -c -p com/zj/usbsdk/UsbController.class
```

Findings:
- `UsbManager.getDeviceList()` → match by VID/PID → `openDevice` →
  iterate interface endpoints, pick **bulk OUT** (`direction != 0x80`) →
  `bulkTransfer()`. **No proprietary handshake** — plain byte pipe.
- `controlTransfer(0xA1, …)` = class-specific IN request → **USB Printer
  Class** `GET_DEVICE_ID` / `GET_PORT_STATUS`. Strong hint the 80 mm printer
  enumerates as printer class 0x07.

VID/PID whitelist from `PrintDemo.java` (`u_infor`):

| VID:PID | |
|---|---|
| 1CBE:0003 | Luminary/TI Stellaris |
| 1CB0:0003 | |
| 0483:5740 | STM32 Virtual COM Port (CDC) |
| 0483:5741 | STM32 |
| 0493:8760 | |
| 0416:5011 | Winbond "POS58" printer class |
| 0416:AABB | Winbond |
| 1659:8965 | |

Image printing in the demo:
```java
byte[] data = PrintPicture.POS_PrintBMP(bmp, 576 /*80mm*/ or 384 /*58mm*/, 0);
send(data);
send({0x1b,0x4a,0x30, 0x1d,0x56,0x42,0x01}); // ESC J 48 (feed), GS V B 1 (cut)
```
`POS_PrintBMP`: resize → grayscale → **threshold** (no dithering!) → `GS v 0`
per line. So the vendor output is poor for photos; we dither ourselves.

### 6. Web research (summary — sources in RESEARCH.md)

- MPT-II = HPRT mobile series; same firmware in GOOJPRT PT-210 & clones.
- BLE: ISSC transparent UART `49535343-FE7D-…` (write `…8841…`), or
  `18F0/2AF1`, or `FF00/FF02`. No flow control → pace writes
  (reference SDK: ~182 B per 40 ms, 24-row strips).
- Density: `ESC 7 n1 n2 n3`.
- No public VID:PID for either exact model → **must measure**.

### 7. Tooling prepared

- `tools/probe.sh [VID:PID]` — lsusb flagging known IDs, device nodes,
  interface class, bound kernel driver.
- `tools/escpos_image.py` — reference photo → GS v 0 encoder.
  Smoke test on a synthetic gradient, 800×500 → width 384:
  ```
  11536 bytes
  1b40 1b61 01 1d7630 00 3000 f000 ...
  ```
  = `ESC @`, `ESC a 1`, `GS v 0 m=0 x=48 (0x30) y=240 (0xF0)` ✔

### 8. Test host

Linux 6.8 (Ubuntu 24.04). `cdc_acm` loaded, `usblp` not yet loaded,
user not in `lp` group → udev rule `linux/99-thermal-printer.rules` (uaccess).

### 9. Research round 2 — official MPT-II manual found

The *MPT-II Programming Manual Rev 1.1* is in
[MYCAMEL222/ArduinoBLE_MPTII_ThermalPrinters](https://github.com/MYCAMEL222/ArduinoBLE_MPTII_ThermalPrinters).
Consequences for the app:

- MP583 darkness changed from `ESC 7` (from PT-210 SDK docs) to **`GS E n`**,
  the only documented control. The harness `density` page now prints
  `GS E 0/5/10/15`, `ESC 7 …` and `DC2 # …` side by side: whichever bars differ
  tell us what the firmware really accepts.
- The manual documents **no real-time status** (`DLE EOT`) — only `ESC v`.
  The harness tries all of them; the app shows "status unknown" when nothing answers.
- 80 mm status bit layout taken from the Xprinter-lineage 80XX manual (proxy);
  encoded in `app/lib/core/status.dart` with unit tests.

Details and sources: RESEARCH.md.

### 10. Hardware test harness + emulator (no hardware needed)

- `tools/hwtest.py` (pyusb / device node / BLE via bleak): `detect`, `dump`
  (descriptors, IEEE-1284 `GET_DEVICE_ID`, `GET_PORT_STATUS`), `status`
  (DLE EOT 1-4, GS r, ESC v, GS a, GS I 1-3/65-69), `print` pages
  (`text ruler gradient bands density modes escstar cut selftest beep photo`),
  `raw <hex>`, `ble-scan`, `ble-dump`. **Every action auto-appends to
  `docs/hardware/<label>/log.md`** (TX/RX hex, timing, `--observe` notes).
- `tools/escpos_render.py`: renders a job to PNG (GS v 0 m0-3, ESC *, text,
  cut marks). Used to verify harness pages and the app's output.

Without the udev rule, pyusb can only list devices (`Access denied` on
config reads) — expected; the rule now matches *any* printer-class interface
via `ENV{ID_USB_INTERFACES}=="*:0701*"` because the HZ-8360's VID:PID is unknown.

### 11. App transports added

- libusb via `dart:ffi` (Linux/macOS): enumerates without opening, ranks
  interfaces printer(07) > CDC(0A) > vendor(FF, only known IDs — otherwise
  phones/ADB show up: a ZTE `19d2:0306` did during testing), detaches
  usblp/cdc_acm, bulk write + bulk-IN status read.
- Windows usbprint via SetupAPI/CreateFile (**unverified**, compiled by CI).
- Debug dump transport (`THERMAL_PHOTO_DUMP=path`) + Linux integration test
  (`flutter test integration_test -d linux`): photo → preview → Print → bytes
  checked; test page checked. Passes.

---

## Next: hardware session (to do)

Setup once: `sudo cp linux/99-thermal-printer.rules /etc/udev/rules.d/ && sudo udevadm control --reload && sudo udevadm trigger`

For each printer (`H="tools/.venv/bin/python tools/hwtest.py --label <model>"`):
0. `$H detect` → `$H dump` → `$H status`
1. `lsusb` before/after plugging → VID:PID
2. `tools/probe.sh VID:PID` → interface class (07 printer / 02+0A CDC / FF vendor), endpoints, driver
3. Self-test page (photo it, note firmware version / codepage / BT name)
4. `tools/escpos_image.py grad.png --width 384|576 --device /dev/usb/lpN` → band/chunk limits
5. MP583: BLE scan → GATT service table
