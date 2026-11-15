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
user not in `lp` group → udev rule `linux/70-thermal-printer.rules` (uaccess).

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

## 2026-11-15 — Session 2: HZ-8360 arrives (USB)

### 12. Enumeration

`lsusb` → `Bus 001 Device 014: ID 0416:5011 Winbond Electronics Corp. Virtual Com Port`

| Field | Value |
|---|---|
| VID:PID | **0416:5011** (in vendor SDK list; lsusb's name "Virtual Com Port" is just the usb.ids entry) |
| iManufacturer / iProduct | `STMicroelectronics` / `POS80 Printer USB` → STM32 MCU using Winbond's VID |
| iSerial | `83600000000` (model number embedded) |
| bcdUSB / bcdDevice | 2.00 / 2.00, MaxPower 100 mA, 1 interface |
| Interface | **class 07/01/02 = USB Printer, bidirectional** |
| Endpoints | EP 0x01 bulk OUT, EP 0x81 bulk IN, 64 B packets |
| Kernel | `usblp` bound → `/dev/usb/lp0` (root:lp 0660) |

Conclusion: plain printer class ⇒ driverless everywhere: Linux usblp/libusb,
Windows usbprint.sys, Android USB host, macOS libusb. Bulk IN present ⇒ status readable.
Full descriptor dump: `docs/hardware/hz8360/usb-descriptors.md`.

Side note: the plug-in watcher first fired on an unrelated Realtek `0bda:8153`
USB-Ethernet adapter (r8152) — discarded.

### 13. Access, status, first prints

- udev gotcha: the rule was first installed as `99-…` → **no effect**, because
  `TAG+="uaccess"` is only turned into ACLs by `73-seat-late.rules`; rules must
  sort before 73. Renamed to `linux/70-thermal-printer.rules` → `getfacl
  /dev/usb/lp0` shows `user:<you>:rw-`, libusb opens the device.
- Printer-class control requests `GET_DEVICE_ID` / `GET_PORT_STATUS` → **STALL**
  (EPIPE): not implemented by the firmware.
- Real-time status over bulk IN **works** (hwtest `status`):

| Query | Reply | Decoded |
|---|---|---|
| `10 04 01` | `16` | online (bit3=0), bit2 = drawer pin high |
| `10 04 02` | `12` | no cover/feed/paper-stop/error |
| `10 04 03` | `12` | no cutter/fatal errors |
| `10 04 04` | `12` | paper OK |
| `1D 72 01` (GS r 1) | `00` | paper present |
| `1B 76` (ESC v) | `00` | answered (MPT-style) |
| `1D 61 FF` / `1D 61 00` (GS a) | `0F` | not the documented 4-byte ASB; meaning unknown |
| `1D 49 n` (GS I) | none / `00` | no ID strings |

- First print attempts produced **blank** paper of the right length; feed
  (`ESC d`) and cut (`GS V B 0`) worked. Cause: **paper roll inserted upside
  down** (thermal coating facing away from head). Flipped → retest.
  Note for users/docs: blank-but-correct-length output = paper upside down.

### 14. Calibration pages (paper flipped)

All via libusb bulk OUT 0x01, no chunk delay, no errors:

| Page | Result |
|---|---|
| text | readable; font/size/bold/align commands honoured |
| ruler (640-dot raster, 576 box) | full 576 box incl. both edges, labels to 512 → **printable width = 576 dots**, left-aligned at 0, excess silently clipped |
| gradient (FS / threshold / 16 steps) | good |
| bands 24…1024 rows per `GS v 0` (up to 72 KB per command) | **all complete** — no buffer limit hit; 130 KB page in 1.9 s (~67 KiB/s, printer-paced via USB NAK) |
| GS v 0 m=0..3 | OK |
| ESC * 33 | OK |
| feed + `GS V B 0` cut | OK |

Consequence: HZ-8360 needs no chunk delay over USB; band height 255 is safe
(1024 also works).

### 15. HZ-8360 in the app; MP583 over Bluetooth

- HZ-8360 via the app (libusb transport): test page + photo print **work**.
- MP583: user paired it via the desktop; app's BLE connection errored.

`bluetoothctl info DC:0D:51:D2:17:F9`:
```
Name: MP583   Class: 0x00040680 (printer)   Paired/Bonded/Trusted: yes   (public address)
UUIDs: SDP, RFCOMM, L2CAP, Serial Port 0x1101, PnP 0x1200,
       0x18F0, e7810a71-73ae-499d-8c15-faa9aef0c3f2, ffcacade-afde-cade-defa-cade00000000
ManufacturerData 0x434B = dc0d51d217f9 (its own MAC)
```
- BT name is **`MP583`**, not `MPT-II` as in the manual.
- **Dual-mode**: Classic SPP + BLE services (18F0 = MPT-II/PT-210 family;
  e7810a71… is the same UUID NIIMBOT label printers use).
- BLE via bleak → `org.bluez.Error.NotAvailable br-connection-profile-unavailable`:
  BlueZ 5.72 picks BR/EDR for a paired dual-mode device with one public address,
  so GATT can't be reached while it's bonded classically. LE scan shows the same
  address only.
- **Classic SPP works without root**: Python `socket(AF_BLUETOOTH, SOCK_STREAM,
  BTPROTO_RFCOMM)` → connect `(MAC, 1)` → print OK.
  Status over SPP: `ESC v` → `00`; `DLE EOT 1` → `12` (online) — so DLE EOT
  **is** supported despite not being in the MPT-II manual.
- App: new `LinuxRfcommTransport` (libc socket via dart:ffi; lists paired
  devices offering UUID 0x1101 via `bluetoothctl`), status readable.

### 16. Windows: driverless paths, verified on the CI runner (no printer)

- **USB printer class (HZ-8360):** Windows binds the inbox usbprint.sys;
  the app opens the `GUID_DEVINTERFACE_USBPRINT` device path from SetupAPI
  and does OVERLAPPED WriteFile/ReadFile with timeouts + CancelIoEx. First
  status byte after open is often junk (0x2B) → one throw-away `DLE EOT 1`.
- **COM ports (MP583 Bluetooth SPP, USB CDC):** SetupAPI
  `GUID_DEVINTERFACE_COMPORT` + friendly names; the outgoing Bluetooth port
  is recognised by the remote MAC in its instance id (incoming has
  000000000000).
- `test_windows/` runs on `windows-2022` before every build:
  enumeration (runner shows `COM2 — Communications Port`), 40 KB overlapped
  write/read round-trip, missing device, and a read on a silent named pipe
  returning empty after 300 ms (= a printer that never answers can't hang
  the app). The round-trip caught a real bug (all chunks written at offset 0).
- Still unverified with a real printer on Windows → test with dev-10.

## Next: hardware session (to do)

Setup once:
```sh
sudo cp linux/70-thermal-printer.rules /etc/udev/rules.d/ && sudo udevadm control --reload && sudo udevadm trigger
```

### HZ-8360 (USB)
```sh
H="tools/.venv/bin/python tools/hwtest.py --label hz8360 --width 576"
lsusb > /tmp/before; # plug in
lsusb | diff /tmp/before - ; tools/probe.sh <VID:PID>
$H detect && $H dump && $H status
$H print selftest                     # ZJ 1F 11 04 — photograph the page
$H print text ruler --observe         # printable width / left offset
$H print gradient bands --observe     # band limit, gaps between bands?
$H print density modes escstar --observe
$H print cut beep --observe
$H print photo --image <jpg> --observe
```
Then: app → Model "HZ-8360" → Connection "USB … (printer)" → Test page → photo.

### MP583 (USB-C, then Bluetooth)
```sh
H="tools/.venv/bin/python tools/hwtest.py --label mp583 --width 384"
# USB first, same as above (self-test: hold FEED + press POWER)
$H detect && $H dump && $H status
$H print text ruler gradient bands density --observe
# BLE
$H ble-scan                            # look for MPT-II / 18F0 / 49535343
$H --ble <MAC> ble-dump
$H --ble <MAC> print text gradient --observe
# Classic SPP (if no BLE)
bluetoothctl -- pair <MAC>             # PIN 0000
sudo systemctl stop ModemManager       # else AT commands get printed
sudo rfcomm bind rfcomm0 <MAC> 1
$H --dev /dev/rfcomm0 status && $H --dev /dev/rfcomm0 print text gradient --observe
```

Record for each: VID:PID, interface class, endpoints, kernel driver, status
replies, max band, darkness command that works, throughput, BLE UUIDs/MTU.
