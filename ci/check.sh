#!/usr/bin/env bash
# firmware/ci/check.sh — the CI gate for every commit (brief §2 ci/, §15).
#
#   1. idf.py build apps/board and apps/node (esp32s3, ESP-IDF v5.5.2)
#   2. fail if sempreiot-node.bin > 1.75 MB (OTA blueprint §1.1)
#   3. build test/host for the linux target and run the Unity tests
#
# Usage: ci/check.sh            (from anywhere; uses ~/.espressif/tools/activate_idf_v5.5.2.sh)
#        IDF_ACTIVATE=/path/to/activate.sh ci/check.sh
# Builds run one after another on purpose: parallel idf.py invocations share
# the component-manager cache and step on each other.
set -euo pipefail

FW_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IDF_ACTIVATE="${IDF_ACTIVATE:-$HOME/.espressif/tools/activate_idf_v5.5.2.sh}"
NODE_MAX_BYTES=$((1792 * 1024))   # 1.75 MB = 1835008 bytes

if [[ -z "${IDF_PATH:-}" ]]; then
    # shellcheck disable=SC1090
    source "$IDF_ACTIVATE" >/dev/null
fi
IDF_PY=(python3 "$IDF_PATH/tools/idf.py")

log() { printf '\n==> %s\n' "$*"; }
fail() { printf '\nCHECK FAILED: %s\n' "$*" >&2; exit 1; }

build_app() {
    local app="$1" dir="$FW_DIR/apps/$1"
    log "build apps/$app (esp32s3)"
    ( cd "$dir"
      [[ -f sdkconfig ]] || "${IDF_PY[@]}" set-target esp32s3 >/dev/null
      "${IDF_PY[@]}" build > "build_ci.log" 2>&1 || { tail -n 60 build_ci.log; fail "apps/$app build"; }
      grep -E "binary size|warning: " build_ci.log | grep -v "BRIDGE_SOFTAP_MAX_CONNECT_NUMBER" || true
      rm -f build_ci.log )
}

build_app board
build_app node

NODE_BIN="$FW_DIR/apps/node/build/sempreiot-node.bin"
NODE_BYTES=$(wc -c < "$NODE_BIN" | tr -d ' ')
log "sempreiot-node.bin = $NODE_BYTES bytes (limit $NODE_MAX_BYTES)"
(( NODE_BYTES <= NODE_MAX_BYTES )) || fail "node image $NODE_BYTES B exceeds 1.75 MB"
BOARD_BYTES=$(wc -c < "$FW_DIR/apps/board/build/sempreiot-board.bin" | tr -d ' ')
log "sempreiot-board.bin = $BOARD_BYTES bytes"

log "build test/host (linux target)"
( cd "$FW_DIR/test/host"
  [[ -f sdkconfig ]] || "${IDF_PY[@]}" --preview set-target linux >/dev/null
  "${IDF_PY[@]}" build > build_ci.log 2>&1 || { tail -n 60 build_ci.log; fail "test/host build"; }
  rm -f build_ci.log )

log "run test/host"
"$FW_DIR/test/host/build/host_tests.elf" || fail "host tests"

log "all checks passed"
