#!/usr/bin/env bash
# firmware/tools/ota_release.sh — build a firmware version and publish it to the Internet
# (docs/ota/ota-internet-plan.md).
#
#   tools/ota_release.sh <version>            build board, node and leaf at <version>, publish them
#   tools/ota_release.sh --bump [patch|minor|major]
#                                             the same, at the next version after the highest published
#   tools/ota_release.sh --list               what is published
#   tools/ota_release.sh --remove <version>   unpublish a version (units already on it keep it)
#
#   options:  --central <Identity ID>  a release for ONE central only (its Identity ID, shown in
#                                 "QR da Central": us-east-1:xxxxxxxx-…). Every action above takes it.
#             --notes "text"      shown on the tablet and the phone beside the version
#             --channel bench     (the only channel until the production key exists, see the plan)
#             --flash 4mb|8mb     board flash size (as ota_images.sh), default 8mb
#             --no-build          publish the images already in firmware/out/ota/<version>/
#             --replace           publish again a version that is already published
#             --dry-run           build and check, write the manifest, upload nothing
#
# Any version may be published, an older one too (to take units back on purpose). The tablet only
# calls the highest published version of a family an "update" for a unit that runs less.
#
# The bucket is organised by version:
#   s3://sempreiot-releases/<channel>/<version>/{board,node,leaf}-<version>.bin
#   s3://sempreiot-releases/<channel>/<version>/manifest.json
#   s3://sempreiot-releases/<channel>/catalog.json        every published version, newest first
# and the catalog is announced, retained, on MQTT topic  sempreiot/releases/<channel>
# (every central hears it at each connect: nothing polls).
# A release for one central lives under centrals/<its Identity ID>/<channel>/… (same layout) and is
# announced, retained, on that central's own topic <Identity ID>/release: no other central hears it
# or can read it (the S3 grant names each central's own folder).
#
# Every release records who published it (git user, AWS identity, machine, commit): --list shows it,
# and the tablet keeps it in the update history.
#
# Needs: `aws login` done, the bucket made by tools/ota_cloud_setup.sh, the signing key
# (docs/ota/signing-key.md). Env: SIOT_RELEASE_BUCKET, SIOT_RELEASE_REGION.
set -euo pipefail

FW_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLS="$FW_DIR/tools"
BUCKET="${SIOT_RELEASE_BUCKET:-sempreiot-releases}"
REGION="${SIOT_RELEASE_REGION:-us-east-1}"
DEV_KEY_FINGERPRINT="797d2b255eccdd8d274b2844a2377170786413362566aa856a3437bc83f0ac82"   # = ci/check.sh

usage() { awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0"; exit 2; }

ACTION=publish VERSION="" BUMP="" CHANNEL=bench NOTES="" FLASH=8mb BUILD=1 REPLACE=0 DRY=0 CENTRAL=""
DEVICE_TABLE="${SIOT_DEVICE_TABLE:-Device}"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --bump) BUMP=patch; [[ "${2:-}" =~ ^(patch|minor|major)$ ]] && { BUMP="$2"; shift; }; shift ;;
        --list) ACTION=list; shift ;;
        --remove) ACTION=remove; VERSION="${2:-}"; shift 2 || usage ;;
        --notes) NOTES="${2:-}"; shift 2 || usage ;;
        --central) CENTRAL="${2:-}"; shift 2 || usage ;;
        --channel) CHANNEL="${2:-}"; shift 2 || usage ;;
        --flash) FLASH="${2:-}"; shift 2 || usage ;;
        --no-build) BUILD=0; shift ;;
        --replace) REPLACE=1; shift ;;
        --dry-run) DRY=1; shift ;;
        -h|--help) usage ;;
        -*) echo "unknown option $1" >&2; usage ;;
        *) [[ -z "$VERSION" ]] || usage; VERSION="$1"; shift ;;
    esac
done
case "$CHANNEL" in bench|stable) ;; *) echo "ERROR: channel is bench or stable" >&2; exit 2 ;; esac
case "$FLASH" in 4mb|8mb) ;; *) usage ;; esac
if [[ "$ACTION" == publish ]]; then
    [[ -n "$VERSION" || -n "$BUMP" ]] || usage
    [[ -z "$VERSION" || -z "$BUMP" ]] || { echo "ERROR: a version or --bump, not both" >&2; exit 2; }
fi

if [[ -z "${IDF_PATH:-}" ]]; then   # same as build.sh
    IDF_ACTIVATE="${IDF_ACTIVATE:-$HOME/.espressif/tools/activate_idf_v5.5.2.sh}"
    while IFS= read -r line; do
        case "$line" in
            SYSTEM_PATH=*|"") ;;
            PATH=*) export PATH="${line#PATH=}:$PATH" ;;
            *) export "${line?}" ;;
        esac
    done < <(bash "$IDF_ACTIVATE" -e)
fi
CAT=(python3 "$TOOLS/ota_catalog.py")
AWS=(aws --region "$REGION")
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# ---- AWS: who, the central, the bucket, the catalog ----------------------------------------------

CALLER="$("${AWS[@]}" sts get-caller-identity --query '[Account,Arn]' --output text 2>/dev/null)" || {
    echo "ERROR: AWS credentials do not work: run 'aws login' first" >&2; exit 1; }
read -r ACCOUNT CALLER_ARN <<< "$CALLER"

# One central, named by its Identity ID — the ID AWS checks: its S3 folder and its MQTT topic are
# named after it (docs/ota/ota-internet-plan.md D11). It is looked up in the Device table the
# central was registered in (lambda/central) only to confirm it exists and to print its name, so a
# typo never publishes to a folder nobody reads.
CENTRAL_JSON=""
if [[ -n "$CENTRAL" ]]; then
    [[ "$CENTRAL" =~ ^[a-z]{2}-[a-z]+-[0-9]:[0-9a-f-]{36}$ ]] \
        || { echo "ERROR: '$CENTRAL' is not an Identity ID (us-east-1:xxxxxxxx-…, in \"QR da Central\")" >&2; exit 1; }
    "${AWS[@]}" dynamodb scan --table-name "$DEVICE_TABLE" --output json \
        --filter-expression "identityId = :v" \
        --expression-attribute-values "{\":v\":{\"S\":\"$CENTRAL\"}}" > "$WORK/central.json"
    CENTRAL_JSON="$("${CAT[@]}" central "$WORK/central.json")" \
        || { echo "ERROR: no central with Identity ID '$CENTRAL' in table $DEVICE_TABLE" >&2; exit 1; }
    IDENTITY="$CENTRAL"
    PREFIX="centrals/$IDENTITY/$CHANNEL"
    TOPIC="$IDENTITY/release"
    echo "central: $("${CAT[@]}" field "$CENTRAL_JSON" name) — Identity ID $IDENTITY"
else
    PREFIX="$CHANNEL"
    TOPIC="sempreiot/releases/$CHANNEL"
fi
S3="s3://$BUCKET/$PREFIX"
HAVE_BUCKET=1
if ! "${AWS[@]}" s3api head-bucket --bucket "$BUCKET" > /dev/null 2>&1; then
    HAVE_BUCKET=0
    if [[ "$DRY" -eq 0 || "$ACTION" != publish ]]; then
        echo "ERROR: bucket $BUCKET not found in account $ACCOUNT: run tools/ota_cloud_setup.sh first" >&2; exit 1
    fi
    echo "note: bucket $BUCKET does not exist yet — the dry run checks against an empty catalog"
fi

# The catalog is the record of what is published: a missing one is empty, an unreadable one stops
# everything (writing over it would lose the history).
: > "$WORK/catalog.json"
if [[ "$HAVE_BUCKET" -eq 1 ]]; then
    if probe="$("${AWS[@]}" s3api head-object --bucket "$BUCKET" --key "$PREFIX/catalog.json" 2>&1)"; then
        "${AWS[@]}" s3 cp --only-show-errors "$S3/catalog.json" "$WORK/catalog.json"
    elif ! grep -qE "Not Found|404" <<< "$probe"; then
        echo "ERROR: cannot read $S3/catalog.json: $probe" >&2; exit 1
    fi
fi

announce() {   # the catalog, retained, to every central (or to the one central)
    local ep
    ep="$("${AWS[@]}" iot describe-endpoint --endpoint-type iot:Data-ATS --query endpointAddress --output text)"
    "${AWS[@]}" iot-data publish --endpoint-url "https://$ep" --topic "$TOPIC" --qos 1 --retain \
        --payload "fileb://$WORK/catalog.out.json"
    echo "announced on $TOPIC (retained)"
}

upload_catalog() {
    "${AWS[@]}" s3 cp --only-show-errors --content-type application/json --cache-control no-cache \
        "$WORK/catalog.out.json" "$S3/catalog.json"
}

case "$ACTION" in
list)
    echo "published on $S3:"
    "${CAT[@]}" list "$WORK/catalog.json"
    exit 0 ;;
remove)
    "${CAT[@]}" has "$WORK/catalog.json" "$VERSION" || { echo "ERROR: $VERSION is not published on $S3" >&2; exit 1; }
    "${CAT[@]}" remove "$WORK/catalog.json" "$VERSION" "$WORK/catalog.out.json"
    upload_catalog
    "${AWS[@]}" s3 rm --only-show-errors --recursive "$S3/$VERSION/"
    announce
    echo "$VERSION removed from $S3. Units that run it keep it."
    exit 0 ;;
esac

# ---- publish -----------------------------------------------------------------------------------

[[ -n "$BUMP" ]] && VERSION="$("${CAT[@]}" bump "$WORK/catalog.json" "$BUMP")"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]] || { echo "ERROR: '$VERSION' is not MAJOR.MINOR.PATCH[-PRE]" >&2; exit 2; }

if [[ "$CHANNEL" == stable ]]; then   # what ci/check.sh --release refuses, refused here too
    [[ "$VERSION" != *-* ]] || { echo "ERROR: stable takes no pre-release ($VERSION)" >&2; exit 1; }
    KEY_NOW="$("$TOOLS/signing_key.sh" status 2>/dev/null | awk '/^fingerprint/{print $2}')"
    [[ "$KEY_NOW" != "$DEV_KEY_FINGERPRINT" ]] || { echo "ERROR: stable is never signed with the development key" >&2; exit 1; }
fi

if "${CAT[@]}" has "$WORK/catalog.json" "$VERSION"; then
    [[ "$REPLACE" -eq 1 ]] || { echo "ERROR: $VERSION is already published on $S3: --replace to publish it again" >&2; exit 1; }
    echo "note: $VERSION is already published — it will be REPLACED (tablets download it again)"
fi
HIGHEST="$("${CAT[@]}" highest "$WORK/catalog.json")"
if [[ -n "$HIGHEST" && "$("${CAT[@]}" cmp "$VERSION" "$HIGHEST")" -lt 0 ]]; then
    echo "note: $VERSION is OLDER than $HIGHEST — published for going back on purpose; it is not offered as an update"
fi

OUT="$FW_DIR/out/ota/$VERSION"
if [[ "$BUILD" -eq 1 ]]; then
    "$TOOLS/ota_images.sh" "$VERSION" --flash "$FLASH" --jump   # the published catalog is the version record now
else
    for fam in board node leaf; do
        [[ -f "$OUT/$fam-$VERSION.bin" ]] || { echo "ERROR: --no-build but $OUT/$fam-$VERSION.bin is missing" >&2; exit 1; }
        "$TOOLS/signing_key.sh" verify "$OUT/$fam-$VERSION.bin" > /dev/null 2>&1 \
            || { echo "ERROR: $fam-$VERSION.bin is NOT signed with the key in use" >&2; exit 1; }
    done
fi

# Who published it: the person (git), the AWS identity, the machine, the source.
GIT_NAME="$(git -C "$FW_DIR" config user.name 2>/dev/null || true)"
GIT_EMAIL="$(git -C "$FW_DIR" config user.email 2>/dev/null || true)"
COMMIT="$(git -C "$FW_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
[[ -z "$(git -C "$FW_DIR" status --porcelain -- . 2>/dev/null)" ]] || COMMIT="$COMMIT+dirty"
"${CAT[@]}" facts "$WORK/facts.json" "$CHANNEL" "$BUCKET" "$REGION" "$NOTES" "$GIT_NAME" "$GIT_EMAIL" \
    "$CALLER_ARN" "$(hostname -s)" "$COMMIT" "$CENTRAL_JSON"
"${CAT[@]}" manifest "$OUT" "$VERSION" "$PREFIX" "$WORK/facts.json" "$OUT/manifest.json"
"${CAT[@]}" add "$WORK/catalog.json" "$OUT/manifest.json" "$WORK/catalog.out.json"

echo
echo "release $VERSION ($S3):"
python3 - "$OUT/manifest.json" <<'EOF'
import json, sys
m = json.load(open(sys.argv[1]))
b = m["published_by"]
print(f"  by {b['who']} <{b['email']}> on {b['host']}, commit {b['commit']}, AWS {b['aws']}")
for fam, i in m["images"].items():
    print(f"  {fam:<6} {i['size']:>8} B  sha256 {i['sha256'][:16]}…  {i['key']}")
EOF

if [[ "$DRY" -eq 1 ]]; then
    cp "$WORK/catalog.out.json" "$OUT/catalog.dry-run.json"
    echo
    echo "dry run: nothing uploaded. Manifest: $OUT/manifest.json, catalog it would publish: $OUT/catalog.dry-run.json"
    exit 0
fi

# Images first, then the manifest, then the catalog — the catalog is what publishes.
for fam in board node leaf; do
    "${AWS[@]}" s3 cp --only-show-errors --content-type application/octet-stream \
        "$OUT/$fam-$VERSION.bin" "$S3/$VERSION/$fam-$VERSION.bin"
done
"${AWS[@]}" s3 cp --only-show-errors --content-type application/json "$OUT/manifest.json" "$S3/$VERSION/manifest.json"
upload_catalog
announce
echo
echo "published: $S3/$VERSION/"
"${CAT[@]}" list "$WORK/catalog.out.json"
