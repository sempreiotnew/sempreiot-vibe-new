#!/bin/sh
# Captures ~60 s of SAFR v3 frames from the mock device into a hex fixture
# used by test/safr/safr_v3_captured_test.dart (no Python required).
#
# Usage: ./capture-safr.sh [/dev/cu.usbserial-XXXX] [seconds]
# Flash + reset the board first; the deterministic Appendix-A vectors are
# emitted ~1.5 s after boot, so start this script BEFORE resetting the board
# (or just let it run across a manual reset).
set -eu

PORT="${1:-$(ls /dev/cu.usbserial-* /dev/cu.SLAB_USBtoUART /dev/cu.wchusbserial* 2>/dev/null | head -1)}"
SECONDS_TO_CAPTURE="${2:-60}"
OUT_DIR="$(cd "$(dirname "$0")/../../mobile/sempreiot_central_app/test/fixtures" && pwd)"
BIN="$(mktemp -t safr_capture)"

[ -n "$PORT" ] || { echo "No serial port found — is the board plugged in?"; exit 1; }
mkdir -p "$OUT_DIR"

echo "Capturing $SECONDS_TO_CAPTURE s from $PORT ..."
stty -f "$PORT" 115200 raw
cat "$PORT" > "$BIN" &
CAT_PID=$!
sleep "$SECONDS_TO_CAPTURE"
kill "$CAT_PID" 2>/dev/null || true

xxd -p "$BIN" | tr -d '\n' > "$OUT_DIR/safr_v3_captured.hex"
echo "Wrote $OUT_DIR/safr_v3_captured.hex ($(wc -c < "$BIN" | tr -d ' ') bytes captured)"
echo "Now run: flutter test test/safr/safr_v3_captured_test.dart"
