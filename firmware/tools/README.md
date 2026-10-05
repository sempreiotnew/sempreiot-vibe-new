# firmware/tools — build, sign and publish firmware

The tools that make the firmware images of the board, the nodes and the detectors (leaf), sign
them, and publish them to the Internet so every central can update from there.

- **Full manual** (every detail, the catalog format, error messages): `docs/ota/ota-tools.md`
- **The design** of the Internet updates: `docs/ota/ota-internet-plan.md`
- **The signing key:** `docs/ota/signing-key.md`
- **Flashing one unit by cable** (identity stickers, ports): the root `tools/README.md` and
  `tools/flash.sh`

| Tool | What it is for |
|---|---|
| [`ota_release.sh`](#1-ota_releasesh--build-and-publish-a-version) | Build a version and **publish it to the Internet** (every central, or one) |
| [`ota_images.sh`](#2-ota_imagessh--the-three-images-of-a-version-manual) | Build the three signed images of a version, to copy to the tablet by hand (**Manual**) |
| [`ota_test_images.sh`](#3-ota_test_imagessh--bench-test-images) | Images for the bench checks (a self-test that fails, unsigned, wrong key, low battery) |
| [`ota_cloud_setup.sh`](#4-ota_cloud_setupsh--the-cloud-once) | Prepare the cloud once: bucket, permissions |
| [`signing_key.sh`](#5-signing_keysh--the-key) | The signing key: status, verify an image, backup, new |
| `ota_catalog.py` | Helper used by `ota_release.sh` (inspect a catalog by hand, see §6) |
| `build_summary.py` | Flash/RAM usage after a build (called by `firmware/build.sh`) |
| `cmake/siot_signing.cmake` | Signs every build (used by every app's CMakeLists) |

---

## Before you start

```bash
# 1. ESP-IDF 5.5.2 (ota_release.sh loads it by itself; the others need it in the shell)
source ~/.espressif/tools/activate_idf_v5.5.2.sh

# 2. The signing key must be there
firmware/tools/signing_key.sh status

# 3. For anything that touches the cloud: your AWS login
aws login
aws sts get-caller-identity          # must print account 644439356850
```

- **Where to run from:** the repository root (`firmware/tools/…`) or `firmware/` (`tools/…`).
  Every script finds its own folder.
- **One build at a time:** two builds side by side break each other.

---

## Quick start

```bash
# Once: the cloud side (bucket and permissions). Safe to run again.
firmware/tools/ota_cloud_setup.sh

# Publish the next version to every central (e.g. 0.3.3 → 0.3.4)
firmware/tools/ota_release.sh --bump --notes "what changed"

# What is published?
firmware/tools/ota_release.sh --list
```

On the tablet the new version shows up by itself:
- a badge on **Atualizar dispositivos**;
- the images in "Firmwares no tablet", tagged **INTERNET**;
- the **Internet** tab of the update bar.

---

## 1. `ota_release.sh` — build and publish a version

```
ota_release.sh <version>                    build board + node + leaf at <version> and publish
ota_release.sh --bump [patch|minor|major]   the same, at the next version after the highest published
ota_release.sh --list                       what is published
ota_release.sh --remove <version>           unpublish a version
```

### Parameters

| Parameter | Values | Default | Meaning |
|---|---|---|---|
| `<version>` | `MAJOR.MINOR.PATCH` or `MAJOR.MINOR.PATCH-PRE` (≤ 24 chars) | — | The version to build and publish. Use a version **or** `--bump`, not both |
| `--bump` | `patch`, `minor`, `major` | `patch` | Next version after the highest **published** one: `0.3.3` → `0.3.4` / `0.4.0` / `1.0.0`. After `0.4.0-dev`, `patch` gives `0.4.0` |
| `--list` | — | — | The published versions: date, sizes, who published, notes |
| `--remove` | `<version>` | — | Unpublish: the catalog no longer has it and its folder is deleted. Units already on it keep it |
| `--central` | an **Identity ID** (`us-east-1:xxxxxxxx-…`) | every central | A release for **one central only**. Works with every action above |
| `--notes` | text | empty | Shown on the tablet and the phone next to the version |
| `--channel` | `bench`, `stable` | `bench` | Today everything is `bench`. `stable` refuses `-dev` versions and the development key |
| `--flash` | `4mb`, `8mb` | `8mb` | Board image: flash size (8 MB product, 4 MB bench devkit) |
| `--no-build` | — | — | Do not build: publish the images already in `firmware/out/ota/<version>/` |
| `--replace` | — | — | Allow publishing a version that is already published (the tablets download it again) |
| `--dry-run` | — | — | Build and check, upload nothing. Works even before the cloud is set up |
| `-h`, `--help` | — | — | Usage |

| Environment variable | Default | Meaning |
|---|---|---|
| `SIOT_RELEASE_BUCKET` | `sempreiot-releases` | S3 bucket |
| `SIOT_RELEASE_REGION` | `us-east-1` | Its region |
| `SIOT_DEVICE_TABLE` | `Device` | DynamoDB table where the centrals are registered (checked by `--central`) |
| `SIOT_SIGNING_KEY` | `~/.sempreiot/keys/sempreiot_dev_signing_key.pem` | The signing key |
| `IDF_ACTIVATE` | `~/.espressif/tools/activate_idf_v5.5.2.sh` | Where ESP-IDF is, when it is not loaded |

### Examples

```bash
# The next patch version, to every central
firmware/tools/ota_release.sh --bump --notes "Leaf: new parent on the same wake"

# A version given by hand
firmware/tools/ota_release.sh 0.4.0 --notes "new siren pattern"

# The next minor version
firmware/tools/ota_release.sh --bump minor --notes "OTA through the Internet"

# A release candidate (pre-release; it is below 0.5.0 in the version order)
firmware/tools/ota_release.sh 0.5.0-rc1 --notes "test before 0.5.0"

# Try first: build and check, nothing is uploaded
firmware/tools/ota_release.sh 0.3.6 --dry-run
cat firmware/out/ota/0.3.6/catalog.dry-run.json

# Publish images that were already built (by ota_images.sh or an earlier dry run)
firmware/tools/ota_release.sh 0.3.6 --no-build --notes "same images as the dry run"

# Publish the same version again (rebuilt); the tablets download it again
firmware/tools/ota_release.sh 0.3.6 --replace --notes "rebuilt"

# Publish an OLDER version, to take units back on purpose (it is never shown as an update)
firmware/tools/ota_release.sh 0.3.3 --no-build --notes "known good version"

# Board image for a 4 MB bench devkit
firmware/tools/ota_release.sh --bump --flash 4mb --notes "bench board"

# What is published, and who published it
firmware/tools/ota_release.sh --list

# Withdraw a version
firmware/tools/ota_release.sh --remove 0.3.6
```

### A release for one central only

```bash
ID=us-east-1:960b9435-b2c7-cad9-8b3e-4ed338720e14     # central-003

firmware/tools/ota_release.sh 0.3.7 --central $ID --notes "fix for this site only"
firmware/tools/ota_release.sh --bump --central $ID           # next after what THIS central has
firmware/tools/ota_release.sh --list --central $ID
firmware/tools/ota_release.sh --remove 0.3.7 --central $ID
```

- **Who sees it:** only that central. Its tablet shows the version tagged **SÓ ESTA CENTRAL**, and
  no other central can hear or download it.
- **Where to find the Identity ID:**
  - on the tablet: menu → **QR da Central** → _Identity ID_;
  - or from its login name, read-only:

```bash
SUB=$(aws cognito-idp admin-get-user --user-pool-id us-east-1_t6mTbVcqB \
      --username central-003@sempreiot.com --query "UserAttributes[?Name=='sub'].Value" --output text)
aws dynamodb get-item --table-name Device --key "{\"subId\":{\"S\":\"$SUB\"}}" \
      --query 'Item.[name.S,identityId.S]' --output text
```

Known today: `central-003` = `us-east-1:960b9435-b2c7-cad9-8b3e-4ed338720e14`,
`central-002` = `us-east-1:960b9435-b271-c27e-0781-73fe64baa097`.

### What you see

```
release 0.3.4 (s3://sempreiot-releases/bench):
  by tallesaugusto <…> on MacBook-Pro, commit 4706fbb, AWS arn:aws:iam::644439356850:root
  board    987136 B  sha256 31d7055c59fca47a…  bench/0.3.4/board-0.3.4.bin
  node    1052672 B  sha256 b82799a4e12fa0f0…  bench/0.3.4/node-0.3.4.bin
  leaf     921600 B  sha256 d84e94902f633094…  bench/0.3.4/leaf-0.3.4.bin
announced on sempreiot/releases/bench (retained)
```

Every release records **who published it**: the git user, the AWS identity, the machine, and the
commit (`+dirty` when there were uncommitted changes). `--list` shows it, and so does the tablet.

### Rules worth knowing

- **Any version can be published, an older one too.** Only the highest published version is
  ever shown as an update; an older one is for going back on purpose.
- **A published version is not overwritten** unless you say `--replace`.
- Every image is checked before upload: its version must be the one given, and it must be the
  right family (a node image named as the board's is refused). The tablet checks again: size,
  SHA-256, family and version. The unit checks the signature.

---

## 2. `ota_images.sh` — the three images of a version (Manual)

```
ota_images.sh <version> [--flash 4mb|8mb] [--jump]
```

| Parameter | Default | Meaning |
|---|---|---|
| `<version>` | — | `MAJOR.MINOR.PATCH[-PRE]` |
| `--flash` | `8mb` | Board flash size |
| `--jump` | off | Allow a version that is not the next one after the last build |

**Output:** `firmware/out/ota/<version>/{board,node,leaf}-<version>.bin`, signed and checked.

```bash
source ~/.espressif/tools/activate_idf_v5.5.2.sh
firmware/tools/ota_images.sh 0.3.6              # the next after the last build (0.3.5)
firmware/tools/ota_images.sh 1.0.0 --jump       # a jump on purpose
firmware/tools/ota_images.sh 0.3.6 --flash 4mb  # board for a 4 MB devkit
```

- **The typo guard:** the version must be the next patch, minor or major after the last folder in
  `firmware/out/ota/`. It exists because 2.2.5 was once built instead of 0.2.5; `--jump` skips it.
- **To use the images by hand:** copy them to the tablet, then **Atualizar dispositivos →
  Manual → Procurar no tablet**.

---

## 3. `ota_test_images.sh` — bench test images

```
ota_test_images.sh <version> [--flash 4mb|8mb]
```

Output in `firmware/out/ota-test/<version>/` (`<next>` = the patch + 1):

| File | What happens when you send it |
|---|---|
| `board/node/leaf-<v>.bin` | a normal update |
| `board/node/leaf-<next>-selftest-fail.bin` | the unit installs it, fails its self-test, rolls back |
| `leaf-<next>-lowbat.bin` | the detector reports 40 % battery: its next offer is refused |
| `board-<v>-UNSIGNED.bin` | refused (no signature) |
| `board-<v>-WRONGKEY.bin` | refused (signed with another key) |

```bash
source ~/.espressif/tools/activate_idf_v5.5.2.sh
firmware/tools/ota_test_images.sh 0.3.6
```

These are bench files: use them through **Manual** only, never publish them.

---

## 4. `ota_cloud_setup.sh` — the cloud, once

```
ota_cloud_setup.sh            create or update everything (safe to run again)
ota_cloud_setup.sh --check    only report, change nothing
```

| Step | What it sets up |
|---|---|
| 1 | Bucket `sempreiot-releases`: private, versioned, encrypted |
| 2 | Tablets may **read** the images: the channel folders and each central's **own** folder only |
| 3 | Every central's IoT permissions: hear the announcements (`sempreiot/releases/*`) |
| 4 | Users' IoT permissions: a phone may ask its central for an update **only under its own identity** |

```bash
firmware/tools/ota_cloud_setup.sh --check     # what is there
firmware/tools/ota_cloud_setup.sh             # make it so
```

| Environment variable | Default |
|---|---|
| `SIOT_RELEASE_BUCKET` | `sempreiot-releases` |
| `SIOT_RELEASE_REGION` | `us-east-1` |

Run it **before** installing an app build that needs a new permission; AWS drops a central that
subscribes where it is not allowed.

---

## 5. `signing_key.sh` — the key

```
signing_key.sh status          which key is in use, its fingerprint
signing_key.sh verify <bin>    is this image signed by the key in use?
signing_key.sh backup <dir>    copy the key somewhere safe (mode 600)
signing_key.sh new             create a NEW key (the old one is kept, dated)
```

```bash
source ~/.espressif/tools/activate_idf_v5.5.2.sh
firmware/tools/signing_key.sh status
firmware/tools/signing_key.sh verify firmware/out/ota/0.3.4/node-0.3.4.bin
firmware/tools/signing_key.sh backup /Volumes/USB-KEY
```

⚠️ **`new` means flashing every unit by cable once:** a unit only accepts images signed with the
key of the image it runs. Read `docs/ota/signing-key.md` first.

---

## 6. `ota_catalog.py` — look inside a catalog

```bash
aws s3 cp s3://sempreiot-releases/bench/catalog.json /tmp/catalog.json
python3 firmware/tools/ota_catalog.py list    /tmp/catalog.json        # the versions
python3 firmware/tools/ota_catalog.py highest /tmp/catalog.json        # the highest
python3 firmware/tools/ota_catalog.py bump    /tmp/catalog.json minor  # what --bump minor would give
python3 firmware/tools/ota_catalog.py cmp 0.3.10 0.3.9                 # 1 (newer), 0, -1
```

---

## Where things end up

| What | Where |
|---|---|
| Images built here | `firmware/out/ota/<version>/` (not in git) |
| Bench test images | `firmware/out/ota-test/<version>/` |
| Published, every central | `s3://sempreiot-releases/bench/<version>/` and `bench/catalog.json` |
| Published, one central | `s3://sempreiot-releases/centrals/<Identity ID>/bench/<version>/` |
| Announcement, every central | MQTT `sempreiot/releases/bench` (retained) |
| Announcement, one central | MQTT `<Identity ID>/release` (retained) |

```bash
# Everything in the bucket
aws s3 ls --recursive s3://sempreiot-releases/

# What a central receives when it connects
EP=$(aws iot describe-endpoint --endpoint-type iot:Data-ATS --query endpointAddress --output text)
aws iot-data get-retained-message --endpoint-url https://$EP --topic sempreiot/releases/bench \
  --query payload --output text | base64 -d | python3 -m json.tool
```

---

## Everyday recipes

| I want to… | Run |
|---|---|
| publish the next version to everybody | `ota_release.sh --bump --notes "…"` |
| check before publishing | `ota_release.sh 0.3.6 --dry-run` |
| fix a published version | publish the next one (`--bump`), or `ota_release.sh 0.3.6 --replace` |
| withdraw a bad version | `ota_release.sh --remove 0.3.6` |
| take units back to an older version | publish it (`ota_release.sh 0.3.3 --no-build`), then on the tablet: Internet → select the units → Atualizar → pick it (bench only: production units refuse older) |
| send a fix to one site only | `ota_release.sh 0.3.6-site1 --central us-east-1:… --notes "…"` |
| see who published what | `ota_release.sh --list` (and `--list --central …`) |
| update by hand with a file | `ota_images.sh 0.3.6`, copy to the tablet, Manual → Procurar no tablet |
| test the rollback / refusals | `ota_test_images.sh 0.3.6`, through Manual |

## When something goes wrong

| Message | What to do |
|---|---|
| `AWS credentials do not work: run 'aws login' first` | `aws login` |
| `bucket sempreiot-releases not found` | `ota_cloud_setup.sh` |
| `<v> is already published … --replace` | Use another version, or `--replace` |
| `'<x>' is not an Identity ID` / `no central with Identity ID` | `--central` takes the Identity ID from "QR da Central", not the Sub ID or the name |
| `… is NOT signed with the key in use` | Rebuild with the key in use (`signing_key.sh status`) |
| `nothing is published yet: give the first version by hand` | The first release needs a version, not `--bump` |
| The tablet says "Aguardando a lista de versões da internet…" | The tablet is not connected to the cloud, or permissions are missing: `ota_cloud_setup.sh --check` |
| "Firmwares no tablet" shows a download error (403/404) | `ota_cloud_setup.sh` (the read permission) |
