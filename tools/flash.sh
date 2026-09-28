#!/usr/bin/env bash
# tools/flash.sh — flash ONE unit: bootloader + partition table + otadata + app
# + its factory identity (nvs_factory), from the product firmware build.
#
#   tools/flash.sh <board|node|leaf> <port> [<sticker-id>] [--model SIOT-XXX-01] [--flash 4mb|8mb | --module n8r8|n4] [--bench] [--erase] [--force]
#
#   Modules (supplier recommendation, 2026-09-25; table in firmware/tools/build_summary.py):
#     8mb = ESP32-S3-WROOM-1-N8R8  8 MB flash + 8 MB PSRAM  -> the board (product)
#     4mb = ESP32-S3-WROOM-1-N4    4 MB flash, no PSRAM     -> the node; 4 MB bench boards
#   The chip's real flash size is read first (esptool flash_id) and must match the
#   build's flash size: an 8 MB image on an N4 would put ota_1/fw_store past the
#   end of the chip, a 4 MB image on an N8R8 is the wrong variant. --force skips it.
#
#   <sticker-id>     optional. Omitted: the id IS the chip's eFuse MAC (12 hex,
#                    e.g. 5A4652000001); tools/stickers/<id>/ is created on first
#                    use (random pop, QR) and reused afterwards. Given: an existing
#                    directory from make_sticker.py or recover_sticker.py.
#                    Every flash leaves tools/stickers/<id>/sticker.png (the QR the
#                    installer app scans) next to sticker.bin; the `qrcode[pil]`
#                    python package is installed into the IDF env on first use.
#   --model          the product written into the unit's factory identity (reference §2.1:
#                    SIOT-SIREN-01, SIOT-PBS-01, SIOT-SMOKE-01, …). Default per image:
#                    board SIOT-BOARD-01, node SIOT-NODE-01, leaf SIOT-LEAF-01. An existing
#                    sticker whose model differs is re-stamped (same id and pop, new bin/json).
#   --flash, --bench the variant built by firmware/build.sh with the same flags
#   --module         (board: build, build-4mb, build-4mb-bench, build-8mb-bench)
#   --erase          erase the whole flash first (also wipes "nvs": the unit
#                    comes back in setup mode)
#   --force          flash even if the detected flash size differs from the build
#   BUILD_DIR=<dir>  env: explicit build directory instead of the flags
#
# Flash size, file offsets and the nvs_factory offset are read from the build
# directory (flasher_args.json + the partition table), so every table works.
set -euo pipefail

usage() { sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
[[ $# -ge 2 ]] || usage

APP="$1"; PORT="$2"; shift 2
STICKER_ID=""
if [[ $# -gt 0 && "$1" != --* ]]; then STICKER_ID="$1"; shift; fi
FLASH=8mb; BENCH=0; ERASE=""; FORCE=""; MODEL=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --model) MODEL="${2:-}"; shift 2 ;;
        --flash) FLASH="${2:-}"; shift 2 ;;
        --module) case "${2:-}" in n8r8|N8R8) FLASH=8mb ;; n4|N4) FLASH=4mb ;; *) usage ;; esac; shift 2 ;;
        --bench) BENCH=1; shift ;;
        --erase) ERASE=1; shift ;;
        --force) FORCE=1; shift ;;
        *) usage ;;
    esac
done
TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FW_DIR="$TOOLS_DIR/../firmware"
case "$APP" in board|node|leaf) ;; *) usage ;; esac
if [[ -z "$MODEL" ]]; then case "$APP" in board) MODEL=SIOT-BOARD-01 ;; node) MODEL=SIOT-NODE-01 ;; leaf) MODEL=SIOT-LEAF-01 ;; esac; fi
case "$FLASH" in 4mb|8mb) ;; *) usage ;; esac
[[ "$APP" == "node" || "$APP" == "leaf" ]] && FLASH=4mb   # node and leaf images are only ever built for the N4

# Same variant → directory rule as firmware/build.sh.
DIR="build"
if [[ "$APP" == "board" ]]; then
    if [[ "$FLASH" == "4mb" ]]; then DIR="build-4mb"; elif [[ "$BENCH" == 1 ]]; then DIR="build-8mb"; fi
    [[ "$BENCH" == 1 ]] && DIR="$DIR-bench"
fi
BUILD="$FW_DIR/apps/$APP/${BUILD_DIR:-$DIR}"
[[ -f "$BUILD/flasher_args.json" ]] || { echo "no build in $BUILD — run firmware/build.sh $APP first" >&2; exit 1; }

if [[ -z "${IDF_PATH:-}" ]]; then
    IDF_ACTIVATE="${IDF_ACTIVATE:-$HOME/.espressif/tools/activate_idf_v5.5.2.sh}"
    while IFS= read -r line; do
        case "$line" in
            SYSTEM_PATH=*|"") ;;
            PATH=*) export PATH="${line#PATH=}:$PATH" ;;
            *) export "${line?}" ;;
        esac
    done < <(bash "$IDF_ACTIVATE" -e)
fi

# ---- one esptool connect: eFuse MAC (identity) + the chip's real flash size ----
CHIP_OUT=$(python3 -m esptool --chip esp32s3 -p "$PORT" flash_id 2>&1) \
    || { echo "$CHIP_OUT" | tail -n 4 >&2; echo "cannot talk to the chip on $PORT (port busy? close idf.py monitor)" >&2; exit 1; }
MAC=$(echo "$CHIP_OUT" | sed -n 's/^MAC: *\([0-9a-fA-F:]\{17\}\).*/\1/p' | head -n 1 | tr 'a-f' 'A-F')
[[ -n "$MAC" ]] || { echo "$CHIP_OUT" >&2; echo "no MAC in esptool output" >&2; exit 1; }
CHIP_FLASH=$(echo "$CHIP_OUT" | sed -n 's/^Detected flash size: *\([0-9]*MB\).*/\1/p' | head -n 1)

# ---- sticker QR: the .png must exist next to sticker.bin (the installer scans it) ----
ensure_qr_lib() {
    python3 -c 'import qrcode, PIL' 2>/dev/null && return 0
    echo "installing qrcode[pil] into the IDF python env (for sticker.png)" >&2
    python3 -m pip install -q "qrcode[pil]" \
        || { echo "warning: pip install qrcode[pil] failed — sticker.png skipped (sticker.json has the payload)" >&2; return 1; }
}
ensure_qr_lib || true

# ---- identity: from the chip's eFuse MAC unless a sticker id was given ----
if [[ -z "$STICKER_ID" ]]; then
    STICKER_ID="${MAC//:/}"
    if [[ ! -f "$TOOLS_DIR/stickers/$STICKER_ID/sticker.bin" ]]; then
        echo "new unit $MAC: creating identity $STICKER_ID (random pop)"
        python3 "$TOOLS_DIR/make_sticker.py" --id "$STICKER_ID" --mac "$MAC" --model "$MODEL" --out-dir "$TOOLS_DIR/stickers"
    else
        echo "unit $MAC: reusing identity tools/stickers/$STICKER_ID/"
    fi
fi
STICKER_BIN="$TOOLS_DIR/stickers/$STICKER_ID/sticker.bin"
[[ -f "$STICKER_BIN" ]] || { echo "no $STICKER_BIN — run tools/make_sticker.py --id $STICKER_ID ... or omit the id" >&2; exit 1; }
# Model on the sticker (reference §2.1): re-stamp an existing unit when it differs, same id + pop.
STICKER_JSON="$TOOLS_DIR/stickers/$STICKER_ID/sticker.json"
if [[ -f "$STICKER_JSON" ]]; then
    HAVE_MODEL=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("model",""))' "$STICKER_JSON")
    if [[ "$HAVE_MODEL" != "$MODEL" ]]; then
        echo "sticker $STICKER_ID: model '${HAVE_MODEL:-none}' -> '$MODEL' (re-stamping, same id and pop)"
        POP=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["pop"])' "$STICKER_JSON")
        python3 "$TOOLS_DIR/make_sticker.py" --id "$STICKER_ID" --pop "$POP" --mac "$MAC" --model "$MODEL" --out-dir "$TOOLS_DIR/stickers" >/dev/null
    fi
fi
STICKER_PNG="$TOOLS_DIR/stickers/$STICKER_ID/sticker.png"
if [[ ! -f "$STICKER_PNG" && -f "$TOOLS_DIR/stickers/$STICKER_ID/sticker.json" ]]; then
    python3 "$TOOLS_DIR/make_sticker.py" --qr-only "$TOOLS_DIR/stickers/$STICKER_ID" >/dev/null || true
fi

# Everything idf.py flash would write, as "offset file" pairs, plus flash settings.
read -r FLASH_SIZE FLASH_MODE FLASH_FREQ < <(python3 - "$BUILD/flasher_args.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
s = d["flash_settings"]
print(s["flash_size"], s["flash_mode"], s["flash_freq"])
PY
)
FLASH_FILES=$(python3 - "$BUILD/flasher_args.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
for off, f in sorted(d["flash_files"].items(), key=lambda kv: int(kv[0], 16)):
    print(off, f)
PY
)
NVS_FACTORY_OFF=$(python3 "$IDF_PATH/components/partition_table/gen_esp32part.py" -q \
    "$BUILD/partition_table/partition-table.bin" | awk -F, '$1=="nvs_factory"{print $4}')
[[ -n "$NVS_FACTORY_OFF" ]] || { echo "no nvs_factory partition in $BUILD's table" >&2; exit 1; }

MODULE="$(python3 "$FW_DIR/tools/build_summary.py" --module "$FLASH_SIZE")"
if [[ -z "$CHIP_FLASH" ]]; then
    echo "warning: esptool did not report the chip's flash size; cannot check it against the $FLASH_SIZE build" >&2
elif [[ "$CHIP_FLASH" != "$FLASH_SIZE" ]]; then
    CHIP_MODULE="$(python3 "$FW_DIR/tools/build_summary.py" --module "$CHIP_FLASH" 2>/dev/null || echo "unknown module")"
    echo "chip on $PORT has $CHIP_FLASH flash ($CHIP_MODULE) but $BUILD is a $FLASH_SIZE build ($MODULE)" >&2
    if [[ "$FORCE" == 1 ]]; then
        echo "--force given: flashing anyway" >&2
    else
        HINT="--flash $(echo "$CHIP_FLASH" | tr "A-Z" "a-z")"
        echo "rebuild + flash with '$HINT' (firmware/build.sh $APP $HINT; tools/flash.sh $APP $PORT $HINT), or pass --force" >&2
        exit 1
    fi
fi
echo "chip: $CHIP_FLASH flash ($MODULE), MAC $MAC"
if [[ "$APP" == "board" && "$BENCH" == 1 ]]; then
    echo "NOTE: --bench build: text console on UART0, tablet link on NATIVE USB (GPIO 19/20)." >&2
    echo "      The tablet will see nothing on $PORT. For a unit wired to the tablet, flash without --bench." >&2
fi
echo "flash $FLASH_SIZE, nvs_factory at $NVS_FACTORY_OFF, files:"
echo "$FLASH_FILES" | sed 's/^/  /'

if [[ "$ERASE" == 1 ]]; then
    python3 -m esptool --chip esp32s3 -p "$PORT" erase_flash
fi

args=()
while read -r off f; do args+=("$off" "$BUILD/$f"); done <<< "$FLASH_FILES"
python3 -m esptool --chip esp32s3 -p "$PORT" -b 460800 --before default_reset --after hard_reset \
    write_flash --flash_mode "$FLASH_MODE" --flash_size "$FLASH_SIZE" --flash_freq "$FLASH_FREQ" \
    "${args[@]}" "$NVS_FACTORY_OFF" "$STICKER_BIN"

echo "flashed sempreiot-$APP ($FLASH_SIZE, $MODULE) + identity $STICKER_ID on $PORT"
if [[ -f "$STICKER_PNG" ]]; then echo "sticker QR: $STICKER_PNG"; else echo "sticker QR: not generated (see warnings above); payload in $TOOLS_DIR/stickers/$STICKER_ID/sticker.json"; fi
