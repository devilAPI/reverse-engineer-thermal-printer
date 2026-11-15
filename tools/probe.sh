#!/usr/bin/env bash
# Probe a freshly plugged-in thermal printer: USB descriptors, kernel driver binding, device nodes.
# Usage: tools/probe.sh            (lists candidate devices)
#        tools/probe.sh VID:PID    (full descriptor dump for one device)
set -u

KNOWN='1cbe:0003|1cb0:0003|0483:5740|0483:5741|0493:8760|0416:5011|0416:aabb|1659:8965|0fe6:811e|28e9:0289|0483:5720|0483:5743|1fc9:2016|6868:0200'

echo "== All USB devices (known thermal-printer IDs marked with *) =="
lsusb | while read -r line; do
  id=$(awk '{print tolower($6)}' <<<"$line")
  if grep -qiE "^($KNOWN)$" <<<"$id"; then echo "* $line"; else echo "  $line"; fi
done

echo
echo "== Device nodes =="
ls -l /dev/usb/lp* /dev/ttyACM* /dev/ttyUSB* /dev/rfcomm* 2>/dev/null || echo "(none)"

echo
echo "== Recent kernel messages =="
journalctl -k -n 30 --no-pager 2>/dev/null | grep -iE 'usb|lp|acm|printer' | tail -15 \
  || dmesg 2>/dev/null | tail -15

if [ $# -ge 1 ]; then
  echo
  echo "== Descriptors for $1 =="
  lsusb -v -d "$1" 2>/dev/null | grep -E 'idVendor|idProduct|iManufacturer|iProduct|iSerial|bInterfaceClass|bInterfaceSubClass|bInterfaceProtocol|bEndpointAddress|wMaxPacketSize|bmAttributes|Transfer Type'
  echo
  echo "== Driver binding =="
  for d in /sys/bus/usb/devices/*; do
    [ -f "$d/idVendor" ] || continue
    if [ "$(cat "$d/idVendor"):$(cat "$d/idProduct")" = "${1,,}" ]; then
      for i in "$d":*; do
        echo "$(basename "$i") class=$(cat "$i/bInterfaceClass") driver=$(basename "$(readlink "$i/driver" 2>/dev/null)" 2>/dev/null)"
      done
    fi
  done
fi
