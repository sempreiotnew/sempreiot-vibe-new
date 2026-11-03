#!/usr/bin/env bash
# prepare_tablet.sh — one-time preparation of an Android tablet that runs the
# SempreIoT central. Run with the tablet on USB (USB debugging on) before the
# app is handed to the site; the settings survive reboots and app updates.
#
#   tools/prepare_tablet.sh                apply
#   tools/prepare_tablet.sh --check        only report
#   tools/prepare_tablet.sh --stay-awake   also keep the screen on while powered
#   tools/prepare_tablet.sh --undo         back to a stock tablet (both settings)
#
# What it does and why:
#  • Battery-optimisation exemption (Doze whitelist). With the screen off and
#    the tablet unplugged, Android's Doze cuts the network for every app that
#    is not on this list — foreground service or not. The central never asks
#    for it with a dialog (nothing on the central prompts); this is where it
#    is set. The app reports it on the console at start-up
#    ("[KeepAlive] ... battery optimisation exempt / NOT exempt").
#  • --stay-awake: Settings.Global.stay_on_while_plugged_in = 7 (AC, USB and
#    wireless). Optional: the links stay alive behind a locked screen either
#    way (CentralLinkService); this only spares the operator the unlock.
#
#  • --undo: removes the app from the Doze whitelist and sets the screen
#    timeout back to the default (stay_on_while_plugged_in = 0) — for tests
#    that need the tablet to behave like a stock one (e.g. to reproduce the
#    frozen-process failure). Run the script again to re-apply.
#
# Vendor battery managers (Samsung "apps em suspensão", Xiaomi "economia de
# bateria" per app) sit on top of Doze and have no ADB switch: on those
# tablets also set the app to "sem restrições" by hand in the battery
# settings. The kiosk (Device Owner) setup will grow into this script.
set -euo pipefail

PKG="com.example.sempreiot_central_app"
CHECK=0
STAY_AWAKE=0
UNDO=0
for arg in "$@"; do
  case "$arg" in
    --check) CHECK=1 ;;
    --stay-awake) STAY_AWAKE=1 ;;
    --undo) UNDO=1 ;;
    -h|--help) sed -n '2,31p' "$0"; exit 0 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

command -v adb >/dev/null || { echo "adb not found (Android platform-tools)" >&2; exit 1; }
state=$(adb get-state 2>/dev/null || true)
[ "$state" = "device" ] || { echo "no tablet on adb (state: ${state:-none}); plug it in and allow USB debugging" >&2; exit 1; }

model=$(adb shell getprop ro.product.model | tr -d '\r')
release=$(adb shell getprop ro.build.version.release | tr -d '\r')
echo "tablet: $model, Android $release"

if ! adb shell pm path "$PKG" >/dev/null 2>&1; then
  echo "app $PKG is not installed on this tablet — install it first" >&2
  exit 1
fi

whitelisted() {
  adb shell dumpsys deviceidle whitelist | tr -d '\r' | grep -q "$PKG"
}

if [ "$CHECK" = 1 ]; then
  if whitelisted; then echo "battery optimisation: exempt (ok)"; else echo "battery optimisation: NOT exempt — run without --check"; fi
  echo "stay on while powered: $(adb shell settings get global stay_on_while_plugged_in | tr -d '\r') (7 = always, 0 = never)"
  exit 0
fi

if [ "$UNDO" = 1 ]; then
  adb shell dumpsys deviceidle whitelist "-$PKG" >/dev/null
  if whitelisted; then
    echo "battery optimisation: could not remove $PKG from the Doze whitelist" >&2
    exit 1
  fi
  echo "battery optimisation: NOT exempt (stock) — Doze will cut the network with the screen off and the tablet unplugged"
  adb shell settings put global stay_on_while_plugged_in 0
  echo "stay on while powered: 0 (stock)"
  echo "done — restart the app once so it reports the new state on the console"
  exit 0
fi

adb shell dumpsys deviceidle whitelist "+$PKG" >/dev/null
if whitelisted; then
  echo "battery optimisation: exempt (ok)"
else
  echo "battery optimisation: could not add $PKG to the Doze whitelist" >&2
  exit 1
fi

if [ "$STAY_AWAKE" = 1 ]; then
  adb shell settings put global stay_on_while_plugged_in 7
  echo "stay on while powered: 7 (AC, USB, wireless)"
fi

echo "done — restart the app once so it reports the new state on the console"
