#!/usr/bin/env python3
"""Wait for a new USB device, then capture everything about it at once.

  tools/.venv/bin/python tools/watch_usb.py [--label NAME] [--timeout 3600]

Writes docs/hardware/<label or vid_pid>/plugin-<time>.md with: lsusb diff,
lsusb -v, sysfs interface classes + bound drivers, kernel log, device nodes,
and (if permitted) the hwtest `dump` + `status` output. Exits after the first
new device, so it can be run in the background as a "notify me" trigger.
"""
import argparse
import datetime as dt
import glob
import os
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PY = sys.executable


def sh(cmd):
    r = subprocess.run(cmd, shell=True, capture_output=True, text=True)
    return (r.stdout + r.stderr).strip()


def devices():
    out = {}
    for d in glob.glob("/sys/bus/usb/devices/*"):
        try:
            vid = open(f"{d}/idVendor").read().strip()
            pid = open(f"{d}/idProduct").read().strip()
            out[os.path.basename(d)] = f"{vid}:{pid}"
        except OSError:
            pass
    return out


def interfaces(sysname):
    rows = []
    for i in sorted(glob.glob(f"/sys/bus/usb/devices/{sysname}:*")):
        def rd(f):
            try:
                return open(f"{i}/{f}").read().strip()
            except OSError:
                return "?"
        drv = os.path.basename(os.readlink(f"{i}/driver")) if os.path.exists(f"{i}/driver") else "(none)"
        eps = " ".join(os.path.basename(e) for e in sorted(glob.glob(f"{i}/ep_*")))
        rows.append(f"{os.path.basename(i)} class={rd('bInterfaceClass')}/{rd('bInterfaceSubClass')}/"
                    f"{rd('bInterfaceProtocol')} driver={drv} endpoints={eps}")
    return "\n".join(rows)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--label")
    ap.add_argument("--timeout", type=int, default=3600)
    a = ap.parse_args()
    before = devices()
    nodes_before = set(glob.glob("/dev/usb/lp*") + glob.glob("/dev/ttyACM*"))
    print(f"watching {len(before)} USB devices for a new one…", flush=True)
    end = time.time() + a.timeout
    new = {}
    while time.time() < end:
        time.sleep(1)
        now = devices()
        new = {k: v for k, v in now.items() if k not in before}
        if new:
            time.sleep(3)  # let drivers bind and nodes appear
            break
    if not new:
        print("timeout, nothing plugged in")
        return 1
    for sysname, vidpid in new.items():
        label = a.label or vidpid.replace(":", "_")
        outdir = ROOT / "docs" / "hardware" / label
        outdir.mkdir(parents=True, exist_ok=True)
        stamp = dt.datetime.now().strftime("%Y%m%d-%H%M%S")
        f = outdir / f"plugin-{stamp}.md"
        nodes = sorted(set(glob.glob("/dev/usb/lp*") + glob.glob("/dev/ttyACM*")) - nodes_before)
        parts = [
            f"# Plug-in capture {vidpid} ({sysname}) {stamp}\n",
            "## Interfaces (sysfs)\n```\n" + interfaces(sysname) + "\n```\n",
            "## New device nodes\n```\n" + (sh(f"ls -l {' '.join(nodes)}") if nodes else "(none)") + "\n```\n",
            "## Kernel log\n```\n" + sh("journalctl -k -n 25 --no-pager 2>/dev/null || dmesg | tail -25") + "\n```\n",
            "## lsusb -v\n```\n" + sh(f"lsusb -v -d {vidpid} 2>&1") + "\n```\n",
            "## hwtest dump\n```\n" + sh(f"{PY} {ROOT}/tools/hwtest.py --label {label} --usb {vidpid} dump 2>&1") + "\n```\n",
            "## hwtest status\n```\n" + sh(f"{PY} {ROOT}/tools/hwtest.py --label {label} --usb {vidpid} status 2>&1") + "\n```\n",
        ]
        f.write_text("\n".join(parts))
        print(f"NEW DEVICE {vidpid} at {sysname} -> {f.relative_to(ROOT)}")
        print(interfaces(sysname))
        print("nodes:", nodes or "(none)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
