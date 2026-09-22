#!/usr/bin/env bash
# firmware/build.sh — build one image in a named variant directory.
#
#   firmware/build.sh <board|node|host> [--flash 4mb|8mb] [--bench] [-- <extra idf.py args>]
#
#   --flash 4mb|8mb  board only: flash module size. 8mb = the product table with
#                    fw_store (default, OTA blueprint §1.2); 4mb = the bench devkits
#                    (partitions_board_4mb.csv). The node is always 4 MB.
#   --bench          board only: text console on UART0 (sdkconfig.bench). Never on
#                    a unit wired to the tablet.
#
# Each variant builds in its own directory, so switching is just another call:
#   apps/board/build            8 MB, product           (idf.py's default dir)
#   apps/board/build-4mb        4 MB
#   apps/board/build-4mb-bench  4 MB + console
#   apps/board/build-8mb-bench  8 MB + console
# tools/flash.sh takes the same flags and flashes from the matching directory.
set -euo pipefail

usage() { sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

APP="${1:-}"; shift || true
case "$APP" in board|node|host) ;; *) usage ;; esac
FLASH=8mb; BENCH=0; EXTRA=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --flash) FLASH="${2:-}"; shift 2 ;;
        --bench) BENCH=1; shift ;;
        --) shift; EXTRA=("$@"); break ;;
        *) usage ;;
    esac
done
case "$FLASH" in 4mb|8mb) ;; *) usage ;; esac

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

# ---- variant → directory + sdkconfig overlays (shared with tools/flash.sh) ----
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
if [[ "$DIR" == "build" ]]; then
    [[ -f sdkconfig ]] || "${IDF_PY[@]}" set-target esp32s3
    exec "${IDF_PY[@]}" build ${EXTRA[@]+"${EXTRA[@]}"}
fi
DEFAULTS="sdkconfig.defaults"
[[ "$FLASH" == "4mb" ]] && DEFAULTS="$DEFAULTS;sdkconfig.4mb"
[[ "$BENCH" == 1 ]] && DEFAULTS="$DEFAULTS;sdkconfig.bench"
echo "==> apps/$APP → $DIR ($DEFAULTS)"
exec "${IDF_PY[@]}" -B "$DIR" -DSDKCONFIG="$DIR/sdkconfig" -DSDKCONFIG_DEFAULTS="$DEFAULTS" build ${EXTRA[@]+"${EXTRA[@]}"}
