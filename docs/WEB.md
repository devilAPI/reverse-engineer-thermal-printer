# Printing from the web app

The web app (https://devilapi.github.io/reverse-engineer-thermal-printer/)
can reach printers in two ways: **browser device APIs** (Chromium only) and
the **web bridge** of the desktop app (every browser).

## What works where

| Browser | MP583 (Bluetooth) | HZ-8360 (USB) | How |
|---|---|---|---|
| Chrome / Edge, Windows & macOS | ✔ Web Serial (Bluetooth SPP) | macOS ✔ WebUSB · Windows: bridge | "Add Bluetooth / serial printer", "Add USB printer" |
| Chrome / Edge, Linux | ✔ Web Serial (Bluetooth SPP) | WebUSB after the udev rule · or bridge | same |
| Chrome, Android | Web Bluetooth (LE) | ✔ WebUSB (OTG) | "Add Bluetooth LE printer", "Add USB printer" |
| Firefox (any OS) | bridge | bridge | "Use desktop app (bridge)" |
| Safari, macOS | bridge via http://127.0.0.1:9632 | same | "Use desktop app" opens that tab |
| Safari, iPhone/iPad | — | — | use the iOS app (BLE) |

Firefox and Safari implement none of Web Serial, WebUSB or Web Bluetooth, and
no page code can change that. They print through the desktop app instead.

## Browser device APIs (Chromium)

A browser only opens a device chooser after a click, so the web app has
**Add …** buttons. A device you picked once is listed again after a reload,
without a prompt (`getPorts()` / `getDevices()`).

- **Web Serial** (`lib/transport/web/web_serial_transport.dart`): USB CDC
  serial printers and Bluetooth Classic SPP. `requestPort()` passes the SPP
  UUID in `allowedBluetoothServiceClassIds`. Pair the printer with the OS
  first (MP583 PIN 0000). The port is opened at 115200 baud and kept open
  for 3 minutes after a job, because Bluetooth connects slowly (RE log §17).
  Status replies (DLE EOT) are read from a background reader.
- **WebUSB** (`webusb_transport.dart`): chooser filter = printer class 07
  plus the vendor-SDK VID/PIDs. It claims the printer interface (ranked
  printer > CDC > vendor, as in libusb) and uses bulk OUT/IN.
  - Linux: `usblp` owns printer-class devices, so `claimInterface` fails
    until `linux/70-thermal-printer.rules` unbinds it. Snap Chromium also
    needs `sudo snap connect chromium:raw-usb`.
  - Windows: `usbprint.sys` owns them, and replacing it with WinUSB (Zadig)
    breaks the driverless desktop path. Use the bridge there.
- **Web Bluetooth** (`web_bluetooth_transport.dart`): GATT write to the
  known printer services (18F0/2AF1, ISSC, FF00, FFE0), 20-byte writes
  paced at 4.5 KB/s.
  - Linux Chrome hides it behind `chrome://flags/#enable-web-bluetooth`, and
    BlueZ refuses LE to the dual-mode MP583 (RE log §15). Use Web Serial on
    desktop.
  - The old web build used `universal_ble`, which called `requestDevice()`
    from the startup scan. That call has no click behind it, so browsers
    reject it. That's why Bluetooth never worked on the web.

## Web bridge (desktop app → any browser)

The desktop app (Linux, macOS, Windows) serves `127.0.0.1:9632`. The
**Web bridge** switch in the printer panel is on by default.

| Request | Meaning |
|---|---|
| `GET /v1/printers` | printers the desktop app sees |
| `POST /v1/print?transport=&id=` | raw ESC/POS body; the app paces it and queries status |
| `GET /v1/status?transport=&id=` | DLE EOT status as text |
| `GET /` → `/reverse-engineer-thermal-printer/…` | the web app itself, proxied from GitHub Pages |

**Security:**
- The bridge binds to loopback only.
- CORS is granted only to `https://devilapi.github.io` and to
  localhost/127.0.0.1 origins. Every other website gets 403, including
  `no-cors` and `<img>` requests, which are caught via `Sec-Fetch-Site`.
- Programs on the same computer (curl) can use it. They could reach the
  printer directly anyway.

**Why the bridge also serves the web app:**
- **Safari** blocks `https://devilapi.github.io` from calling
  `http://127.0.0.1` as mixed content (verified in WebKit, RE log §18). The
  page must come from the bridge's own origin. On the https site, "Use
  desktop app" in Safari opens http://127.0.0.1:9632 in a new tab.
- **Chrome** asks once for "local network access" (apps on this device)
  when the https site calls the bridge. Allow it.
- **Firefox** treats 127.0.0.1 as secure and works from the https site
  directly.

The proxy keeps the last copy of each file in memory, so a reload still
works offline while the desktop app runs.

## Tests

- `app/test/bridge_test.dart` checks the origin allowlist, 403 for other
  sites, the Private Network Access preflight, exact bytes forwarded, the
  status reply, 404 for an unknown printer, and the busy port.
- `tools/web_e2e.mjs` (Playwright) drives the real web build in Chromium,
  Firefox and WebKit:
  ```sh
  # bridge with the dump transport (or BRIDGE_E2E_REAL=1 for real printers)
  BRIDGE_E2E_SECONDS=600 THERMAL_PHOTO_DUMP=/tmp/job.bin \
    flutter test test/bridge_test.dart --plain-name 'e2e harness' &
  node tools/web_e2e.mjs http://localhost:8099/ chromium --mock-devices   # Web Serial/USB/Bluetooth with fake devices
  node tools/web_e2e.mjs http://127.0.0.1:9632/ chromium firefox webkit  # bridge-served app
  node tools/web_e2e.mjs https://devilapi.github.io/ --serve-as=app/build/web firefox webkit  # real https origin
  ```
