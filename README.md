# Thermal Photo

Open-source, **driverless**, multi-platform Flutter app that prints photos on cheap
Chinese ESC/POS thermal receipt printers. Targets:

- **MP583** — 58 mm mobile printer (Bluetooth "MPT-II" + USB-C), 384 dots
- **HZ-8360** — 80 mm desktop printer with cutter (USB / LAN / BT), 576 dots

## Layout

| Path | What |
|---|---|
| `app/` | Flutter app (Android, iOS, Linux, macOS, Windows, Web) |
| `app/lib/core/` | Pure Dart: image pipeline (dithering), ESC/POS encoder, printer profiles |
| `app/lib/receipt/` | Receipt editor model, JSON, rasteriser, job encoder (see `docs/RECEIPT_EDITOR.md`) |
| `app/lib/transport/` | Byte pipes — see table below |
| `tools/hwtest.py` | Hardware harness: detect/dump/status/test pages/raw/BLE — auto-logs to `docs/hardware/` |
| `tools/escpos_render.py` | ESC/POS → PNG emulator to check jobs without paper |
| `tools/probe.sh`, `tools/escpos_image.py` | Quick USB probe, reference photo encoder |
| `linux/70-thermal-printer.rules` | udev rule granting the desktop user raw printer access |
| `docs/RESEARCH.md` | Protocol & hardware findings with sources |
| `docs/REVERSE_ENGINEERING_LOG.md` | Step-by-step lab notebook of the reverse engineering |
| `.github/workflows/` | CI: every push to `master` → tests + Android/Linux/Windows/macOS/iOS/web builds → `dev-N` prerelease; web on GitHub Pages |

## Transports (all driverless)

| Transport | Platforms | Status |
|---|---|---|
| libusb (dart:ffi) | Linux, macOS | ✔ HZ-8360 prints on Linux |
| Device node `/dev/usb/lp*`, `/dev/ttyACM*`, `/dev/rfcomm*`, `/dev/cu.*` | Linux, macOS | ✔ HZ-8360 via `/dev/usb/lp0` |
| Bluetooth SPP (RFCOMM socket, no root) | Linux | ✔ MP583 prints; link kept open between jobs |
| Windows usbprint (SetupAPI + overlapped I/O) | Windows | CI-tested, unverified with a printer |
| Windows COM ports (Bluetooth SPP, USB CDC) | Windows | CI-tested, unverified with a printer |
| Android USB host (Kotlin channel) | Android | compiled, awaits hardware |
| BLE (`universal_ble`) | Android, iOS, macOS, Windows, Linux | MP583 BLE blocked by BlueZ dual-mode on Linux |
| Web Serial / WebUSB / Web Bluetooth | Chrome, Edge (web) | mock-tested in Chromium, see docs/WEB.md |
| Web bridge (desktop app on 127.0.0.1:9632) | every browser incl. Firefox & Safari | ✔ e2e-tested in Chromium, Firefox, WebKit |
| Raw TCP 9100 | all but Web | awaits LAN model |
| Debug dump (`THERMAL_PHOTO_DUMP=file`) | desktop | ✔ integration-tested |

### Web app: which browser?

Chrome/Edge talk to printers directly (Web Serial for the MP583 over
Bluetooth, WebUSB). Firefox and Safari have no device APIs. They print
through the desktop app's **web bridge**: run the desktop app and press "Use
desktop app" in the web app, or open http://127.0.0.1:9632 (Safari needs
this). Details: [docs/WEB.md](docs/WEB.md).

### Bluetooth on Linux: slow-to-answer printers

The MP583 takes ~4.5 s to answer a Bluetooth connection request, right at
the kernel's default 5.12 s page timeout, so single attempts often fail
with "Host is down". The app retries and keeps the link open for 3 minutes
between prints. If connecting is still flaky, raise the page timeout to
10.24 s (resets when the adapter is power-cycled or replugged):

```sh
sudo hciconfig hci0 pageto 16384
```

(BlueZ's `PageTimeout=` in `/etc/bluetooth/main.conf` is ignored by kernel
6.8, see docs/REVERSE_ENGINEERING_LOG.md §17.)

## How printing works

photo → EXIF rotate → scale to printer width → tone (brightness/contrast/gamma)
→ dither (Floyd–Steinberg / Atkinson / Bayer / threshold) → 1-bit pack
→ `ESC @`, `GS v 0` bands, feed/cut → chunked write to the transport.

## Receipt editor

The **Receipt** tab builds receipts, notes and labels from blocks — text
(fonts, sizes, bold/underline/inverted), item/price columns with dot leaders,
separators, dithered images, QR codes, barcodes (Code 128, EAN-13…), feeds and
cuts — with a live preview, undo/redo, `{date}`/`{time}`/`{n}` placeholders,
built-in templates, saved receipts and JSON import/export. Receipts are
rasterised in the app at the printer's dot width (any Unicode, no code pages)
and printed with the same connection and settings as photos. Details:
[docs/RECEIPT_EDITOR.md](docs/RECEIPT_EDITOR.md).

## Develop

Local testing is done on the **Linux desktop build** only; the other platforms are built by CI.

```sh
sudo apt install clang cmake ninja-build pkg-config libgtk-3-dev
sudo cp linux/70-thermal-printer.rules /etc/udev/rules.d/ && sudo udevadm control --reload && sudo udevadm trigger
cd app
flutter test
flutter run -d linux
# end-to-end without hardware:
THERMAL_PHOTO_DUMP=/tmp/job.bin flutter test integration_test -d linux
python3 ../tools/escpos_render.py /tmp/job.bin --width 384 -o /tmp/paper.png
```

Hardware harness (once the udev rule is installed):

```sh
python3 -m venv tools/.venv && tools/.venv/bin/pip install pyusb pyserial pillow bleak
H="tools/.venv/bin/python tools/hwtest.py --label hz8360 --width 576"
$H detect; $H dump; $H status
$H print text ruler gradient bands density cut --observe
```

## License

MIT — see [LICENSE](LICENSE).
