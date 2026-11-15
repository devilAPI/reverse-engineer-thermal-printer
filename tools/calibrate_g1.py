#!/usr/bin/env python3
"""Compute G1's per-line "space above" so every line's first ink row lands on
its measured target (dots relative to the store-ID line).

  cd app && G1_CALIBRATE=1 flutter test test/receipt_test.dart --plain-name 'G1 calibration' \\
      | grep -oE 'G1CAL.*' | python3 ../tools/calibrate_g1.py

Input lines: "G1CAL head <h>" then "G1CAL <target> <height> <inkTop>" per line.
Prints the Dart list for g1Before and the expected residual per line.
"""
import sys

GAP_AFTER_HEAD = 8  # blank dots between "BRAND" block and the first store line

head = None
rows = []
for line in sys.stdin:
    parts = line.split()
    if len(parts) >= 3 and parts[1] == "head":
        head = int(parts[2])
    elif len(parts) == 4:
        rows.append(tuple(int(p) for p in parts[1:]))
if head is None or not rows:
    sys.exit("no calibration data")

target0, _, off0 = rows[0]
anchor = head + GAP_AFTER_HEAD + off0 - target0  # absolute row of target 0
cursor = head
before = []
for target, height, off in rows:
    b = anchor + target - off - cursor
    if b < 0:
        print(f"// WARNING: line at {target} overlaps previous by {-b} dots", file=sys.stderr)
        b = 0
    before.append(b)
    cursor += b + height

print("const g1Before = <int>[")
print("  " + ", ".join(str(b) for b in before) + ", //")
print("];")
# verify
cursor = head
worst = 0
for (target, height, off), b in zip(rows, before):
    top = cursor + b + off
    err = top - (anchor + target)
    worst = max(worst, abs(err))
    cursor += b + height
print(f"// max residual {worst} dots", file=sys.stderr)
