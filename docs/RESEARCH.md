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
| Density | `ESC 7 n1 n2 n3` (heat dots, heat time ≈80, interval ≈2) | 🔎 [pt210 commands](https://goojprt-pt210-sdk.readthedocs.io/en/latest/api/commands.html) |
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

## Known quirks (generic Chinese ESC/POS)

- `0416:5011` (Winbond/GD32 "POS58") binds `usblp`; CUPS quirk `unidir soft-reset`. [gist](https://gist.github.com/fawkesley/f4554d40bedbbb45fbeddb0bcae566ee)
- `0483:5740` = STM32 virtual COM port (CDC-ACM). [gist](https://gist.github.com/imrehg/10950229)
- Always strip large images into bands; some firmware caps `yH ≤ 8`.
- Leftover garbage after images reported in [python-escpos#367](https://github.com/python-escpos/python-escpos/issues/367) → send `ESC @` before each job.

## Driverless transport matrix (plan)

| Platform | USB | Bluetooth | Network |
|---|---|---|---|
| Linux | `/dev/usb/lp*` or `/dev/ttyACM*` (udev rule `linux/99-thermal-printer.rules`); libusb fallback | BLE (`universal_ble`/BlueZ); SPP via `/dev/rfcomm*` | TCP 9100 |
| macOS | libusb (FFI) or `/dev/cu.usbmodem*` if CDC | BLE | TCP 9100 |
| Windows | printer class: usbprint via SetupAPI + `CreateFile` (no Zadig); CDC: COM port | BLE (WinRT) | TCP 9100 |
| Android | USB Host API bulk transfer (platform channel) | BLE; SPP optional | TCP 9100 |
| iOS | ✗ (no USB accessory without MFi) | BLE only | TCP 9100 |
| Web (Chromium) | WebUSB (Linux/macOS/Android; Windows needs WinUSB) / Web Serial for CDC | Web Bluetooth | ✗ |

## Flutter packages considered

- `universal_ble` — BLE on all 6 platforms, MIT. **Chosen.** (`flutter_blue_plus` rejected: non-OSS commercial license terms.)
- `image` — decode / EXIF / resize. Dithering + ESC/POS encoding written in-house (`lib/core`) — existing ESC/POS packages are stale and don't dither.
- USB: `quick_usb` (stale), `dart_libusb` (FFI, desktop) — decide after hardware probe.
