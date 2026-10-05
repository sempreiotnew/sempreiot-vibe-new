#!/usr/bin/env bash
# firmware/ci/check.sh — the CI gate for every commit (brief §2 ci/, §15).
#
#   1. idf.py build apps/board, apps/node and apps/leaf (esp32s3, ESP-IDF v5.5.2)
#   2. fail if sempreiot-node.bin or sempreiot-leaf.bin > 1.75 MB (OTA blueprint §1.1)
#      and if any image is not signed with the key in use (docs/ota/signing-key.md)
#   3. build test/host for the linux target and run the Unity tests
#
#   4. the production gate (docs/ota/before-production.md): everything that is relaxed
#      for the bench is listed as a WARNING; with --release it FAILS the check
#
# Usage: ci/check.sh            (from anywhere; uses ~/.espressif/tools/activate_idf_v5.5.2.sh)
#        ci/check.sh --release  the same, and nothing relaxed for the bench may be left
#        IDF_ACTIVATE=/path/to/activate.sh ci/check.sh
# Builds run one after another on purpose: parallel idf.py invocations share
# the component-manager cache and step on each other.
set -euo pipefail

RELEASE=0
[[ "${1:-}" == "--release" ]] && RELEASE=1
FW_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IDF_ACTIVATE="${IDF_ACTIVATE:-$HOME/.espressif/tools/activate_idf_v5.5.2.sh}"
NODE_MAX_BYTES=$((1792 * 1024))   # 1.75 MB = 1835008 bytes

if [[ -z "${IDF_PATH:-}" ]]; then
    # The activate script refuses to be sourced from a script ($0 check) and
    # is not `set -u` clean; its -e mode prints KEY=VALUE lines instead.
    [[ -f "$IDF_ACTIVATE" ]] || { echo "no ESP-IDF activate script at $IDF_ACTIVATE" >&2; exit 1; }
    while IFS= read -r line; do
        case "$line" in
            SYSTEM_PATH=*|"") ;;
            PATH=*) export PATH="${line#PATH=}:$PATH" ;;   # tool dirs only: prepend
            *) export "${line?}" ;;
        esac
    done < <(bash "$IDF_ACTIVATE" -e)
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
build_app leaf

log "build apps/board --flash 4mb (bench table)"
"$FW_DIR/build.sh" board --flash 4mb > "$FW_DIR/apps/board/build_ci.log" 2>&1 \
    || { tail -n 60 "$FW_DIR/apps/board/build_ci.log"; fail "apps/board 4mb build"; }
rm -f "$FW_DIR/apps/board/build_ci.log"

NODE_BIN="$FW_DIR/apps/node/build/sempreiot-node.bin"
NODE_BYTES=$(wc -c < "$NODE_BIN" | tr -d ' ')
log "sempreiot-node.bin = $NODE_BYTES bytes (limit $NODE_MAX_BYTES)"
(( NODE_BYTES <= NODE_MAX_BYTES )) || fail "node image $NODE_BYTES B exceeds 1.75 MB"
LEAF_BYTES=$(wc -c < "$FW_DIR/apps/leaf/build/sempreiot-leaf.bin" | tr -d ' ')
log "sempreiot-leaf.bin = $LEAF_BYTES bytes (limit $NODE_MAX_BYTES)"
(( LEAF_BYTES <= NODE_MAX_BYTES )) || fail "leaf image $LEAF_BYTES B exceeds 1.75 MB"
BOARD_BYTES=$(wc -c < "$FW_DIR/apps/board/build/sempreiot-board.bin" | tr -d ' ')
log "sempreiot-board.bin = $BOARD_BYTES bytes"

# Every image that could be released is signed (docs/ota/signing-key.md): an
# unsigned or wrongly signed .bin fails the gate here, before it reaches a unit.
for img in board/build/sempreiot-board.bin board/build-4mb/sempreiot-board.bin \
           node/build/sempreiot-node.bin leaf/build/sempreiot-leaf.bin; do
    log "signature of apps/$img"
    "$FW_DIR/tools/signing_key.sh" verify "$FW_DIR/apps/$img" > /dev/null 2>&1 \
        || fail "apps/$img is not signed with the key in use (tools/signing_key.sh status)"
done

log "build test/host (linux target)"
( cd "$FW_DIR/test/host"
  [[ -f sdkconfig ]] || "${IDF_PY[@]}" --preview set-target linux >/dev/null
  "${IDF_PY[@]}" build > build_ci.log 2>&1 || { tail -n 60 build_ci.log; fail "test/host build"; }
  rm -f build_ci.log )

log "run test/host"
"$FW_DIR/test/host/build/host_tests.elf" || fail "host tests"

# ---- the production gate (docs/ota/before-production.md) -------------------------
# One line per thing that is relaxed for the bench. Add a line here in the same
# change that relaxes something; remove it only when the thing is restored.
DEV_KEY_FINGERPRINT="797d2b255eccdd8d274b2844a2377170786413362566aa856a3437bc83f0ac82"
RELAXED=()
for app in board node leaf; do
    cfg="$FW_DIR/apps/$app/sdkconfig"
    grep -q '^CONFIG_SIOT_OTA_TEST_ANY_VERSION=y' "$cfg" && RELAXED+=("item 1  apps/$app: CONFIG_SIOT_OTA_TEST_ANY_VERSION=y — accepts the same or an older firmware version")
    grep -q '^CONFIG_SIOT_OTA_ALLOW_FORCE=y'      "$cfg" && RELAXED+=("item 2  apps/$app: CONFIG_SIOT_OTA_ALLOW_FORCE=y — honours FORCE (downgrade)")
    grep -q '^CONFIG_SIOT_OTA_SELFTEST_FAIL=y'    "$cfg" && RELAXED+=("item 3  apps/$app: CONFIG_SIOT_OTA_SELFTEST_FAIL=y — an image that never confirms itself")
    grep -q '^CONFIG_SECURE_SIGNED_APPS_NO_SECURE_BOOT=y' "$cfg" || grep -q '^CONFIG_SECURE_BOOT=y' "$cfg" \
        || RELAXED+=("item 4  apps/$app: the image is NOT signed")
done
KEY_NOW="$("$FW_DIR/tools/signing_key.sh" status 2>/dev/null | awk '/^fingerprint/{print $2}')"
[[ "$KEY_NOW" == "$DEV_KEY_FINGERPRINT" ]] && RELAXED+=("item 5  signed with the DEVELOPMENT key (${DEV_KEY_FINGERPRINT:0:8}…), not the production key")
grep -q -- '-' "$FW_DIR/VERSION" && RELAXED+=("item 6  firmware/VERSION is a pre-release: $(tr -d '\n' < "$FW_DIR/VERSION")")
OTA_PIN_POLICY="$FW_DIR/../mobile/sempreiot_central_app/lib/features/central/application/ota_pin_policy.dart"
grep -q '^const otaPinOncePerSession = true;' "$OTA_PIN_POLICY" 2>/dev/null \
    && RELAXED+=("item 8  tablet: the update PIN is asked once per app session (otaPinOncePerSession)")
grep -q 'CHANNEL=bench ' "$FW_DIR/tools/ota_release.sh" \
    && RELAXED+=("item 9  Internet releases: one channel, 'bench' — no 'stable' channel for customers yet (ota_release.sh default)")

if (( ${#RELAXED[@]} > 0 )); then
    printf '\n==> %s\n' "RELAXED FOR THE BENCH — must be restored before production (docs/ota/before-production.md):"
    for r in "${RELAXED[@]}"; do printf '      %s\n' "$r"; done
    (( RELEASE == 0 )) || fail "--release: ${#RELAXED[@]} item(s) above are not allowed in a release"
elif (( RELEASE == 1 )); then
    log "production gate: nothing relaxed"
fi

log "all checks passed"
