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
| `app/lib/transport/` | Byte pipes: device node, TCP 9100, BLE (more to come: USB host, WebUSB) |
| `tools/` | `probe.sh` (USB enumeration), `escpos_image.py` (reference encoder for hardware tests) |
| `linux/99-thermal-printer.rules` | udev rule granting the desktop user raw printer access |
| `docs/RESEARCH.md` | Protocol & hardware findings with sources |
| `docs/REVERSE_ENGINEERING_LOG.md` | Step-by-step lab notebook of the reverse engineering |
| `.github/workflows/` | CI: every push to `master` → tests + Android/Linux/Windows/macOS/iOS/web builds → `dev-N` prerelease; web on GitHub Pages |

## How printing works

photo → EXIF rotate → scale to printer width → tone (brightness/contrast/gamma)
→ dither (Floyd–Steinberg / Atkinson / Bayer / threshold) → 1-bit pack
→ `ESC @`, `GS v 0` bands, feed/cut → chunked write to the transport.

## Develop

Local testing is done on the **Linux desktop build** only; the other platforms are built by CI.

```sh
sudo apt install clang cmake ninja-build pkg-config libgtk-3-dev
sudo cp linux/99-thermal-printer.rules /etc/udev/rules.d/ && sudo udevadm control --reload && sudo udevadm trigger
cd app
flutter test
flutter run -d linux
```

## License

MIT — see [LICENSE](LICENSE).
