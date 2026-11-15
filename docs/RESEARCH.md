# Printer research notes

Status legend: ✅ confirmed (vendor docs / hardware) · 🔎 from the web, unverified · ❓ unknown, measure on hardware

## MP583 — 58 mm mobile printer

| Item | Value | Source |
|---|---|---|
| Paper / print width | 58 mm / 48 mm = **384 dots** @ 203 dpi | ✅ user manual (repo root PDF) |
| Interfaces | Bluetooth + USB Type-C | ✅ manual |
| BT name / PIN | `MPT-II` / `0000` | ✅ manual |
| Bitmap limits | 40 KB per bitmap, 64 KB total | ✅ manual |
| Family | HPRT "MPT-II" firmware, also sold as GOOJPRT PT-210 etc. | 🔎 [manualshive](https://manualshive.com/ru/manual/hprt/mpt-ii-series/2176397?page=6), [ArduinoBLE_MPTII](https://github.com/MYCAMEL222/ArduinoBLE_MPTII_ThermalPrinters) |
| BLE GATT | ISSC `49535343-FE7D-…` svc, write `49535343-8841-…`; or `18F0`/`2AF1`; or `FF00`/`FF02` | 🔎 [bitbank2/Thermal_Printer](https://github.com/bitbank2/Thermal_Printer), [goojprt-pt210-sdk](https://goojprt-pt210-sdk.readthedocs.io/en/latest/api/constants.html) |
| Classic BT | SPP `00001101-…`, RFCOMM ch 1 | 🔎 same |
| **Official manual** | *MPT-II Programming Manual Rev 1.1* (HPRT/Hanin 2015) | 🔎 [MYCAMEL222/ArduinoBLE_MPTII_ThermalPrinters](https://github.com/MYCAMEL222/ArduinoBLE_MPTII_ThermalPrinters) |
| Darkness | **`GS E n`** (1D 45 n) "head control": dot-line time 0.8 ms + n·0.1 ms, n=0..15 — the only documented control. `ESC 7` is *not* in the MPT-II manual (PT-210 SDK docs claim it) | 🔎 manual |
| Status | **No `DLE EOT`, `GS r`, `GS a`, `GS I`** in the manual. Only `ESC v` (1B 76 → 1 byte, paper/ready; manual says serial only, wording garbled) | 🔎 manual — test with `hwtest.py status` |
| Buffers | ~3 KB receive buffer; 40 KB per bitmap, 76 KB total; BT "no need to consider flow control" | 🔎 manual |
| GS v 0 quirk | Character modes (double width…) *do* apply to raster images on MPT-II → always `ESC @` first | 🔎 manual |
| ESC * | m=0,1,32,33; single-density max 384 cols, double max 192 | 🔎 manual |
| BT version | "Bluetooth 4.0 class 2", name `MPT-II`/`BL`, PIN 0000, ≤8 paired hosts; prints via SPP; PT-210 clone also BLE `18F0/2AF1` | 🔎 manual + repo |
| BLE pacing | 24-row GS v 0 strips, ~182 B writes, 40 ms between writes; no flow control | 🔎 [pt210 transport](https://goojprt-pt210-sdk.readthedocs.io/en/latest/api/transport.html) |
| USB VID:PID / class | ❓ printer class (0x07) or CDC-ACM? | measure: `tools/probe.sh` |

## HZ-8360 (HZTZ, aka POS-8360) — 80 mm desktop with cutter

| Item | Value | Source |
|---|---|---|
| Print width | 72 mm = **576 dots** @ 203 dpi | ✅ vendor SDK (`nPaperWidth = 576`) |
| Command set | ESC/POS (Zijiang "zj" SDK, `cn.com.zj.*`) | ✅ vendor package (RAR) |
| Raster | `GS v 0 m xL xH yL yH d…`, ≤ 4095 rows / command | ✅ 80MM Programmer Manual p.24 |
| Cut | vendor demo: `ESC J 0x30` + `GS V B 1`; `GS V B n` = feed n + partial cut | ✅ SDK `PrintDemo.java` |
| USB | plain bulk-OUT endpoint write; `controlTransfer(0xA1, …)` = USB printer-class GET_DEVICE_ID/PORT_STATUS | ✅ disassembled `usbsdk.jar` |
| VID:PID list in vendor SDK | 1CBE:0003, 1CB0:0003, 0483:5740, 0483:5741, 0493:8760, 0416:5011, 0416:AABB, 1659:8965 | ✅ SDK |
| Interfaces | USB, LAN (raw TCP 9100), optional BT | 🔎 [manuals.plus](https://ca.manuals.plus/ae/1005006846074457) |
| Windows | generic "POS-80" driver on `USB001` → usbprint ⇒ likely printer class | 🔎 inference |
| Actual VID:PID | ❓ | measure |

## HZ-8360 status & control (proxy: Xprinter-lineage "80XX Programmer Manual")

Source: [80XX_Programmer_Manual.pdf](https://blog.lambda.cx/posts/xprinter-wifi/80XX_Programmer_Manual.pdf) — not the exact firmware, verify.

| Query | Reply bits (bit1 & bit4 always 1 → idle = `0x12`) |
|---|---|
| `10 04 01` printer | bit3 offline |
| `10 04 02` offline cause | bit2 cover open, bit3 FEED pressed, bit5 stopped by paper end, bit6 error |
| `10 04 03` error | bit3 cutter error, bit5 unrecoverable, bit6 auto-recoverable |
| `10 04 04` paper | 0x0C near end, 0x60 paper end |
| `1D 61 n` ASB | 4 bytes: b1 0x08 offline/0x20 cover; b2 0x08 cutter; b3 0x03 near end/0x0C out |

- Cut: `GS V 0/1/49` partial (no full cut); `GS V 66 n` feed n + cut.
- Self-test: `1F 11 04` (ZJ "US vt eot", also in vendor SDK `Command.java`).
- Buzzer: `ESC B n t` (forum-sourced).
- LAN default IP: **192.168.123.100** (one vendor) or **192.168.1.87** (another) — read from self-test page; web config at `http://<ip>`.
- Set IP over USB: `1F 1B 1F 91 00 49 50 a b c d` (beeps on success). 🔎 [vendor PDF](https://cdn.shopify.com/s/files/1/0491/6759/7721/files/configure_IP_address_for_Ethernet_port_printers.pdf)

## Known quirks (generic Chinese ESC/POS)

- `0416:5011` (Winbond/GD32 "POS58") binds `usblp`; CUPS quirk `unidir soft-reset`. [gist](https://gist.github.com/fawkesley/f4554d40bedbbb45fbeddb0bcae566ee)
- `0483:5740` = STM32 virtual COM port (CDC-ACM). [gist](https://gist.github.com/imrehg/10950229)
- Always strip large images into bands; some firmware caps `yH ≤ 8`.
- Neither Linux `usblp` nor CUPS has quirk entries for any of our IDs (the "0416:5011 unidir" claim is unverified). `usblp` supports `read()` on bidirectional interfaces.
- Linux SPP: `bluetoothctl pair` → `rfcomm bind rfcomm0 <MAC>`; stop ModemManager or it sends AT commands that get printed.
- Windows usbprint raw I/O: first bulk-IN byte after open is often junk (0x2B) → do a throw-away `DLE EOT`; send one `DLE EOT` per write.
- WebUSB: printer class 0x07 is **not** a protected class, but an interface already bound to an OS driver (usbprint/usblp) can't be claimed.
- Photo quality: Atkinson (diffuses 3/4 of error) holds up better than Floyd–Steinberg against thermal dot gain; brighten/gamma before dithering. No grey-scale modes documented on either printer.
- Leftover garbage after images reported in [python-escpos#367](https://github.com/python-escpos/python-escpos/issues/367) → send `ESC @` before each job.

## Driverless transport matrix (plan)

| Platform | USB | Bluetooth | Network |
|---|---|---|---|
| Linux | `/dev/usb/lp*` or `/dev/ttyACM*` (udev rule `linux/99-thermal-printer.rules`); libusb fallback | BLE (`universal_ble`/BlueZ); SPP via `/dev/rfcomm*` | TCP 9100 |
| macOS | libusb (FFI) or `/dev/cu.usbmodem*` if CDC | BLE | TCP 9100 |
| Windows | printer class: usbprint via SetupAPI + `CreateFile` (no Zadig) — 🔎 [escpos crate](https://docs.rs/crate/escpos/latest/source/examples/usbprint.rs); CDC: inbox usbser.sys → COM port (Win10+, class 02/02) | BLE (WinRT) | TCP 9100 |
| Android | USB Host API bulk transfer (platform channel) | BLE; SPP optional | TCP 9100 |
| iOS | ✗ (no USB accessory without MFi) | BLE only | TCP 9100 |
| Web (Chromium) | WebUSB (Linux/macOS/Android; Windows needs WinUSB) / Web Serial for CDC | Web Bluetooth | ✗ |

## Flutter packages considered

- `universal_ble` — BLE on all 6 platforms, MIT. **Chosen.** (`flutter_blue_plus` rejected: non-OSS commercial license terms.)
- `image` — decode / EXIF / resize. Dithering + ESC/POS encoding written in-house (`lib/core`) — existing ESC/POS packages are stale and don't dither.
- USB: `quick_usb` (stale), `dart_libusb` (FFI, desktop) — decide after hardware probe.
