#!/usr/bin/env bash
# firmware/build.sh — build one image in a named variant directory.
#
#   firmware/build.sh <board|node|leaf|host> [--flash 4mb|8mb | --module n8r8|n4] [--bench] [-- <extra idf.py args>]
#
#   Modules (supplier recommendation, 2026-09-25; table in tools/build_summary.py):
#     8mb = ESP32-S3-WROOM-1-N8R8  8 MB flash + 8 MB PSRAM  -> the board (product)
#     4mb = ESP32-S3-WROOM-1-N4    4 MB flash, no PSRAM     -> the node; 4 MB bench boards
#
#   --flash 4mb|8mb  board only: flash size. 8mb = the product table with fw_store
#   --module n8r8|n4 (default, OTA blueprint §1.2); 4mb = the bench devkits
#                    (partitions_board_4mb.csv). Same flag, spelled either way.
#                    The node and the leaf are always 4 MB (N4).
#   --bench          board only: text console on UART0 (sdkconfig.bench). Never on
#                    a unit wired to the tablet: the tablet link is UART0 in every
#                    other build (sdkconfig.defaults), on N4 and N8R8 alike.
#
# Each variant builds in its own directory, so switching is just another call:
#   apps/board/build            8 MB, product           (idf.py's default dir)
#   apps/board/build-4mb        4 MB
#   apps/board/build-4mb-bench  4 MB + console (tablet link moves to native USB)
#   apps/board/build-8mb-bench  8 MB + console (tablet link moves to native USB)
#   apps/leaf/build             4 MB, battery detector (no Mesh-Lite)
# tools/flash.sh takes the same flags and flashes from the matching directory.
#
# After a successful board/node build, tools/build_summary.py prints the flash
# usage: every partition with its size, what is written into it and the free
# space, the app image vs. its OTA slot, unassigned flash, and static RAM.
set -euo pipefail

usage() { sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

APP="${1:-}"; shift || true
case "$APP" in board|node|leaf|host) ;; *) usage ;; esac
FLASH=8mb; BENCH=0; EXTRA=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --flash) FLASH="${2:-}"; shift 2 ;;
        --module) case "${2:-}" in n8r8|N8R8) FLASH=8mb ;; n4|N4) FLASH=4mb ;; *) usage ;; esac; shift 2 ;;
        --bench) BENCH=1; shift ;;
        --) shift; EXTRA=("$@"); break ;;
        *) usage ;;
    esac
done
case "$FLASH" in 4mb|8mb) ;; *) usage ;; esac
[[ "$APP" == "node" || "$APP" == "leaf" ]] && FLASH=4mb   # node and leaf images are only ever built for the N4

FW_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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
IDF_PY=(python3 "$IDF_PATH/tools/idf.py")

# ---- variant → directory + sdkconfig overlays (same rule in tools/flash.sh) ----
variant_dir() {  # <app> <flash> <bench>
    local app="$1" flash="$2" bench="$3"
    if [[ "$app" != "board" ]]; then echo "build"; return; fi
    local d="build"
    if [[ "$flash" == "4mb" ]]; then d="build-4mb"; elif [[ "$bench" == 1 ]]; then d="build-8mb"; fi
    [[ "$bench" == 1 ]] && d="$d-bench"
    echo "$d"
}

if [[ "$APP" == "host" ]]; then
    cd "$FW_DIR/test/host"
    [[ -f sdkconfig ]] || "${IDF_PY[@]}" --preview set-target linux
    exec "${IDF_PY[@]}" build ${EXTRA[@]+"${EXTRA[@]}"}
fi

cd "$FW_DIR/apps/$APP"
DIR="$(variant_dir "$APP" "$FLASH" "$BENCH")"
LINK=uart0; [[ "$BENCH" == 1 ]] && LINK=usb
MODULE="$(python3 "$FW_DIR/tools/build_summary.py" --module "${FLASH%mb}MB")"
if [[ "$DIR" == "build" ]]; then
    [[ -f sdkconfig ]] || "${IDF_PY[@]}" set-target esp32s3
    echo "==> apps/$APP → $DIR (sdkconfig.defaults) for $MODULE, tablet link: $LINK"
    "${IDF_PY[@]}" build ${EXTRA[@]+"${EXTRA[@]}"}
else
    DEFAULTS="sdkconfig.defaults"
    [[ "$FLASH" == "4mb" ]] && DEFAULTS="$DEFAULTS;sdkconfig.4mb"
    [[ "$BENCH" == 1 ]] && DEFAULTS="$DEFAULTS;sdkconfig.bench"
    echo "==> apps/$APP → $DIR ($DEFAULTS) for $MODULE, tablet link: $LINK"
    "${IDF_PY[@]}" -B "$DIR" -DSDKCONFIG="$DIR/sdkconfig" -DSDKCONFIG_DEFAULTS="$DEFAULTS" build ${EXTRA[@]+"${EXTRA[@]}"}
fi
# set -e already aborted on a failed build; only a successful build reaches here.
python3 "$FW_DIR/tools/build_summary.py" "$DIR" "apps/$APP → $DIR"
