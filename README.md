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
| libusb (dart:ffi) | Linux, macOS | enumerates on Linux ✔, printing awaits hardware |
| Device node `/dev/usb/lp*`, `/dev/ttyACM*`, `/dev/rfcomm*`, `/dev/cu.*` | Linux, macOS | awaits hardware |
| Windows usbprint (SetupAPI + CreateFile) | Windows | compiled, unverified |
| Android USB host (Kotlin channel) | Android | compiled, awaits hardware |
| BLE (`universal_ble`) | all incl. iOS & Web | awaits hardware |
| Raw TCP 9100 | all but Web | awaits LAN model |
| Debug dump (`THERMAL_PHOTO_DUMP=file`) | desktop | ✔ integration-tested |

## How printing works

photo → EXIF rotate → scale to printer width → tone (brightness/contrast/gamma)
→ dither (Floyd–Steinberg / Atkinson / Bayer / threshold) → 1-bit pack
→ `ESC @`, `GS v 0` bands, feed/cut → chunked write to the transport.

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
