#!/usr/bin/env bash
# firmware/tools/ota_test_images.sh — the images for the bench checks of OTA step 1
# (docs/phases-development/phase3-ota-brief.md §7, O1–O5).
#
#   tools/ota_test_images.sh <version> [--flash 4mb|8mb]
#
# <version> must be NEWER than what the bench board runs (firmware/VERSION is 0.1.0-dev today,
# so e.g. 0.1.1). Nothing of the normal builds is touched: every image is built in its own
# directory (apps/<app>/build-ota-*) with the version given, and copied to
# firmware/out/ota-test/<version>/ :
#
#   board-<version>.bin                 good board image                       → O2, O3
#   board-<next>-selftest-fail.bin      board image that fails its self-test   → O4 (rolls back)
#   node-<version>.bin                  good node image                        → O5, O7 (stored, then rolled out)
#   node-<next>-selftest-fail.bin       node image that fails its self-test    → a node rolls back
#   leaf-<version>.bin                  good leaf image                        → O12 (offer in the ACK, pull, self-test)
#   leaf-<next>-selftest-fail.bin       leaf image that fails its self-test    → a leaf rolls back on its next wake
#   leaf-<next>-lowbat.bin              leaf image whose (mock) battery is 40 % → O13: install it, then the NEXT offer is refused
#   board-<version>-UNSIGNED.bin        the same board image without signature → O1 (refused)
#   board-<version>-WRONGKEY.bin        signed with a throw-away key           → O1 (refused)
#
# <next> = <version> with its patch number + 1, so the failing image is newer than the good one
# and can be pushed after it. Copy the files to the tablet and pick them in "Atualização de
# firmware". The throw-away key is deleted at the end.
set -euo pipefail

FW_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:-}"; shift || true
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]] || { sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
FLASH=8mb
while [[ $# -gt 0 ]]; do
    case "$1" in
        --flash) FLASH="${2:-}"; shift 2 ;;
        *) echo "unknown argument $1" >&2; exit 2 ;;
    esac
done
: "${IDF_PATH:?run: source ~/.espressif/tools/activate_idf_v5.5.2.sh}"
IDF_PY=(python3 "$IDF_PATH/tools/idf.py")
ESPSECURE=(python3 "$IDF_PATH/components/esptool_py/esptool/espsecure.py")

BASE="${VERSION%%-*}"; PRE=""; [[ "$VERSION" == *-* ]] && PRE="-${VERSION#*-}"
IFS=. read -r MA MI PA <<< "$BASE"
NEXT="$MA.$MI.$((PA + 1))$PRE"
OUT="$FW_DIR/out/ota-test/$VERSION"
mkdir -p "$OUT"

# build <app> <dir> <version> [extra sdkconfig fragment]
build() {
    local app="$1" dir="$2" ver="$3" extra="${4:-}"
    local defaults="sdkconfig.defaults"
    [[ "$app" == "board" && "$FLASH" == "4mb" ]] && defaults="$defaults;sdkconfig.4mb"
    [[ -n "$extra" ]] && defaults="$defaults;$extra"
    echo "==> apps/$app $ver → $dir"
    ( cd "$FW_DIR/apps/$app"
      rm -rf "$dir"   # the version is read when the build is configured: always from scratch
      SIOT_VERSION="$ver" "${IDF_PY[@]}" -B "$dir" -DSDKCONFIG="$dir/sdkconfig" \
          -DSDKCONFIG_DEFAULTS="$defaults" build > "$dir.log" 2>&1 \
          || { tail -n 40 "$dir.log"; echo "build failed: apps/$app/$dir.log" >&2; exit 1; }
      rm -f "$dir.log" )
}

FRAG="$OUT/selftest-fail.sdkconfig"
printf 'CONFIG_SIOT_OTA_SELFTEST_FAIL=y\n' > "$FRAG"

build board build-ota-good "$VERSION"
build board build-ota-fail "$NEXT" "$FRAG"
build node  build-ota-good "$VERSION"
build node  build-ota-fail "$NEXT" "$FRAG"
build leaf  build-ota-good "$VERSION"
build leaf  build-ota-fail "$NEXT" "$FRAG"
LOWBAT="$OUT/lowbat.sdkconfig"
printf 'CONFIG_SIOT_SENSOR_MOCK_BATTERY_PCT=40\n' > "$LOWBAT"
build leaf  build-ota-lowbat "$NEXT" "$LOWBAT"

cp "$FW_DIR/apps/board/build-ota-good/sempreiot-board.bin"          "$OUT/board-$VERSION.bin"
cp "$FW_DIR/apps/board/build-ota-good/sempreiot-board-unsigned.bin" "$OUT/board-$VERSION-UNSIGNED.bin"
cp "$FW_DIR/apps/board/build-ota-fail/sempreiot-board.bin"          "$OUT/board-$NEXT-selftest-fail.bin"
cp "$FW_DIR/apps/node/build-ota-good/sempreiot-node.bin"            "$OUT/node-$VERSION.bin"
cp "$FW_DIR/apps/node/build-ota-fail/sempreiot-node.bin"            "$OUT/node-$NEXT-selftest-fail.bin"
cp "$FW_DIR/apps/leaf/build-ota-good/sempreiot-leaf.bin"            "$OUT/leaf-$VERSION.bin"
cp "$FW_DIR/apps/leaf/build-ota-fail/sempreiot-leaf.bin"            "$OUT/leaf-$NEXT-selftest-fail.bin"
cp "$FW_DIR/apps/leaf/build-ota-lowbat/sempreiot-leaf.bin"          "$OUT/leaf-$NEXT-lowbat.bin"

WRONG="$OUT/throwaway_key.pem"
"${ESPSECURE[@]}" generate_signing_key --version 2 --scheme rsa3072 "$WRONG" > /dev/null
"${ESPSECURE[@]}" sign_data --version 2 --keyfile "$WRONG" \
    --output "$OUT/board-$VERSION-WRONGKEY.bin" "$OUT/board-$VERSION-UNSIGNED.bin" > /dev/null
rm -f "$WRONG" "$FRAG" "$LOWBAT"

echo
echo "images in $OUT:"
for f in "$OUT"/*.bin; do
    printf '  %-44s %8d B  sha256 %s\n' "$(basename "$f")" "$(wc -c < "$f" | tr -d ' ')" \
        "$(shasum -a 256 "$f" | cut -c1-16)…"
done
echo
"$FW_DIR/tools/signing_key.sh" verify "$OUT/board-$VERSION.bin" > /dev/null 2>&1 \
    && echo "board-$VERSION.bin: signed with the key in use (good)"
"$FW_DIR/tools/signing_key.sh" verify "$OUT/board-$VERSION-WRONGKEY.bin" > /dev/null 2>&1 \
    && { echo "ERROR: the WRONGKEY image verifies with the real key" >&2; exit 1; } \
    || echo "board-$VERSION-WRONGKEY.bin: NOT signed with the key in use (as intended)"
