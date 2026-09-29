#!/usr/bin/env bash
# firmware/tools/signing_key.sh — the firmware signing key (docs/ota/signing-key.md).
#
#   signing_key.sh status          where the key is looked up, whether it is there, its fingerprint
#   signing_key.sh new             make a NEW key (the old file is kept beside it, dated)
#   signing_key.sh verify <bin>    is this image signed by the key in use?
#   signing_key.sh backup <dir>    copy the key to <dir> (a disk / vault you control), mode 600
#
# The key in use is $SIOT_SIGNING_KEY, else ~/.sempreiot/keys/sempreiot_dev_signing_key.pem —
# the same rule as firmware/tools/cmake/siot_signing.cmake.
set -euo pipefail

KEY="${SIOT_SIGNING_KEY:-$HOME/.sempreiot/keys/sempreiot_dev_signing_key.pem}"
: "${IDF_PATH:?run: source ~/.espressif/tools/activate_idf_v5.5.2.sh}"
ESPSECURE=(python3 "$IDF_PATH/components/esptool_py/esptool/espsecure.py")

fingerprint() {  # SHA-256 of the public key (DER): safe to write down, names the key
    openssl pkey -in "$1" -pubout -outform DER 2>/dev/null | openssl dgst -sha256 | awk '{print $NF}'
}

case "${1:-}" in
status)
    echo "key in use : $KEY"
    if [[ -f "$KEY" ]]; then
        echo "present    : yes ($(stat -f '%Sp' "$KEY" 2>/dev/null || stat -c '%A' "$KEY"))"
        echo "fingerprint: $(fingerprint "$KEY")"
    else
        echo "present    : NO — 'signing_key.sh new' makes one, or copy the team's key there"
        exit 1
    fi
    ;;
new)
    mkdir -p "$(dirname "$KEY")"; chmod 700 "$(dirname "$KEY")"
    if [[ -f "$KEY" ]]; then
        OLD="${KEY%.pem}.replaced-$(date +%Y%m%d-%H%M%S).pem"
        mv "$KEY" "$OLD"; chmod 600 "$OLD"
        echo "the previous key was kept as $OLD"
        echo "(units that run an image signed with it accept updates signed with IT only)"
    fi
    "${ESPSECURE[@]}" generate_signing_key --version 2 --scheme rsa3072 "$KEY"
    chmod 600 "$KEY"
    echo "new key    : $KEY"
    echo "fingerprint: $(fingerprint "$KEY")"
    echo
    echo "NEXT: 1. write the fingerprint into docs/ota/signing-key.md"
    echo "      2. back the key up:  $0 backup <dir>"
    echo "      3. rebuild (firmware/build.sh ...) and flash EVERY unit by cable once:"
    echo "         a unit signed with the previous key refuses images signed with this one."
    ;;
verify)
    [[ -n "${2:-}" ]] || { echo "usage: $0 verify <image.bin>"; exit 2; }
    "${ESPSECURE[@]}" verify_signature --version 2 --keyfile "$KEY" "$2"
    ;;
backup)
    [[ -n "${2:-}" && -d "${2:-}" ]] || { echo "usage: $0 backup <existing dir>"; exit 2; }
    [[ -f "$KEY" ]] || { echo "no key at $KEY"; exit 1; }
    cp "$KEY" "$2/"; chmod 600 "$2/$(basename "$KEY")"
    echo "copied to $2/$(basename "$KEY")  (fingerprint $(fingerprint "$KEY"))"
    ;;
*)
    sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
