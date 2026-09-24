#!/usr/bin/env bash
# tools/flash.sh — flash ONE unit: bootloader + partition table + otadata + app
# + its factory identity (nvs_factory), from the product firmware build.
#
#   tools/flash.sh <board|node> <port> [<sticker-id>] [--flash 4mb|8mb] [--bench] [--erase]
#
#   <sticker-id>     optional. Omitted: the id IS the chip's eFuse MAC (12 hex,
#                    e.g. 5A4652000001); tools/stickers/<id>/ is created on first
#                    use (random pop, QR) and reused afterwards. Given: an existing
#                    directory from make_sticker.py or recover_sticker.py.
#   --flash, --bench the variant built by firmware/build.sh with the same flags
#                    (board: build, build-4mb, build-4mb-bench, build-8mb-bench)
#   --erase          erase the whole flash first (also wipes "nvs": the unit
#                    comes back in setup mode)
#   BUILD_DIR=<dir>  env: explicit build directory instead of the flags
#
# Flash size, file offsets and the nvs_factory offset are read from the build
# directory (flasher_args.json + the partition table), so every table works.
set -euo pipefail

usage() { sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
[[ $# -ge 2 ]] || usage

APP="$1"; PORT="$2"; shift 2
STICKER_ID=""
if [[ $# -gt 0 && "$1" != --* ]]; then STICKER_ID="$1"; shift; fi
FLASH=8mb; BENCH=0; ERASE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --flash) FLASH="${2:-}"; shift 2 ;;
        --bench) BENCH=1; shift ;;
        --erase) ERASE=1; shift ;;
        *) usage ;;
    esac
done
TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FW_DIR="$TOOLS_DIR/../firmware"
case "$APP" in board|node) ;; *) usage ;; esac
case "$FLASH" in 4mb|8mb) ;; *) usage ;; esac

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

# ---- identity: from the chip's eFuse MAC unless a sticker id was given ----
if [[ -z "$STICKER_ID" ]]; then
    MAC_OUT=$(python3 -m esptool --chip esp32s3 -p "$PORT" read_mac 2>&1) \
        || { echo "$MAC_OUT" | tail -n 4 >&2; echo "cannot read the MAC on $PORT (port busy? close idf.py monitor)" >&2; exit 1; }
    MAC=$(echo "$MAC_OUT" | sed -n 's/^MAC: *\([0-9a-fA-F:]\{17\}\).*/\1/p' | head -n 1 | tr 'a-f' 'A-F')
    [[ -n "$MAC" ]] || { echo "$MAC_OUT" >&2; echo "no MAC in esptool output" >&2; exit 1; }
    STICKER_ID="${MAC//:/}"
    if [[ ! -f "$TOOLS_DIR/stickers/$STICKER_ID/sticker.bin" ]]; then
        echo "new unit $MAC: creating identity $STICKER_ID (random pop)"
        python3 "$TOOLS_DIR/make_sticker.py" --id "$STICKER_ID" --mac "$MAC" --out-dir "$TOOLS_DIR/stickers"
    else
        echo "unit $MAC: reusing identity tools/stickers/$STICKER_ID/"
    fi
fi
STICKER_BIN="$TOOLS_DIR/stickers/$STICKER_ID/sticker.bin"
[[ -f "$STICKER_BIN" ]] || { echo "no $STICKER_BIN — run tools/make_sticker.py --id $STICKER_ID ... or omit the id" >&2; exit 1; }

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

echo "flashed sempreiot-$APP ($FLASH_SIZE) + identity $STICKER_ID on $PORT"
