#!/usr/bin/env bash
# firmware/tools/ota_images.sh — the real OTA images of one version: board, node and leaf.
#
#   tools/ota_images.sh <version> [--flash 4mb|8mb]
#
# <version> must be NEWER than what the units run (firmware/VERSION is 0.1.0-dev today, so
# e.g. 0.1.1). Nothing of the normal builds is touched: every image is built in its own
# directory (apps/<app>/build-ota) with the version given, signed with the key in use
# (docs/ota/signing-key.md), and copied to firmware/out/ota/<version>/ :
#
#   board-<version>.bin                 board image  → pushed from the tablet ("Atualização de firmware")
#   node-<version>.bin                  node image   → stored on the board, rolled out through the mesh
#   leaf-<version>.bin                  leaf image   → offered in the ACK, pulled by the leaf on its next wake
#
# Copy the files to the tablet and pick them in "Atualização de firmware". The test images
# (self-test failure, low battery, unsigned, wrong key) come from tools/ota_test_images.sh.
set -euo pipefail

FW_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:-}"; shift || true
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]] || { sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
FLASH=8mb
while [[ $# -gt 0 ]]; do
    case "$1" in
        --flash) FLASH="${2:-}"; shift 2 ;;
        *) echo "unknown argument $1" >&2; exit 2 ;;
    esac
done
: "${IDF_PATH:?run: source ~/.espressif/tools/activate_idf_v5.5.2.sh}"
IDF_PY=(python3 "$IDF_PATH/tools/idf.py")

OUT="$FW_DIR/out/ota/$VERSION"
mkdir -p "$OUT"

# build <app> <dir> <version>
build() {
    local app="$1" dir="$2" ver="$3"
    local defaults="sdkconfig.defaults"
    [[ "$app" == "board" && "$FLASH" == "4mb" ]] && defaults="$defaults;sdkconfig.4mb"
    echo "==> apps/$app $ver → $dir"
    ( cd "$FW_DIR/apps/$app"
      rm -rf "$dir"   # the version is read when the build is configured: always from scratch
      SIOT_VERSION="$ver" "${IDF_PY[@]}" -B "$dir" -DSDKCONFIG="$dir/sdkconfig" \
          -DSDKCONFIG_DEFAULTS="$defaults" build > "$dir.log" 2>&1 \
          || { tail -n 40 "$dir.log"; echo "build failed: apps/$app/$dir.log" >&2; exit 1; }
      rm -f "$dir.log" )
}

for app in board node leaf; do
    build "$app" build-ota "$VERSION"
    cp "$FW_DIR/apps/$app/build-ota/sempreiot-$app.bin" "$OUT/$app-$VERSION.bin"
done

echo
echo "images in $OUT:"
for f in "$OUT"/*.bin; do
    printf '  %-24s %8d B  sha256 %s\n' "$(basename "$f")" "$(wc -c < "$f" | tr -d ' ')" \
        "$(shasum -a 256 "$f" | cut -c1-16)…"
done
echo
for app in board node leaf; do
    "$FW_DIR/tools/signing_key.sh" verify "$OUT/$app-$VERSION.bin" > /dev/null 2>&1 \
        && echo "$app-$VERSION.bin: signed with the key in use" \
        || { echo "ERROR: $app-$VERSION.bin is NOT signed with the key in use" >&2; exit 1; }
done
