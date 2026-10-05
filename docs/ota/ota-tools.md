# OTA tools — building, signing and publishing firmware (manual)

_Written 2026-10-05. Every tool that makes or publishes a firmware image, with every parameter, its
output, and the recipes for everyday work. The design behind the Internet part is
`docs/ota/ota-internet-plan.md`; the key is `docs/ota/signing-key.md`; what is still relaxed for the
bench is `docs/ota/before-production.md`. A shorter, example-first version sits next to the scripts:
`firmware/tools/README.md`._

---

## 0. The whole path at a glance

```
 firmware/VERSION ─┐
                   ▼
  build.sh ──────────────► apps/<app>/build*/sempreiot-<app>.bin        everyday builds, flashed by cable
                                                                        (tools/flash.sh)
  ota_images.sh <v> ─────► firmware/out/ota/<v>/{board,node,leaf}-<v>.bin
        │                  signed, checked                              → Manual: copy to the tablet,
        │                                                                 "Procurar no tablet"
        ▼
  ota_release.sh <v> ────► s3://sempreiot-releases/<channel>/<v>/…      → Internet: every central hears
     (calls ota_images.sh,  + catalog.json + MQTT retained catalog        the catalog, downloads, shows
      ota_catalog.py)                                                     the badge
        │
        └─ --central <Identity ID> ─► centrals/<Identity ID>/<channel>/<v>/…   → one central only

  ota_test_images.sh <v> ► firmware/out/ota-test/<v>/…                  bench checks (self-test fail,
                                                                        unsigned, wrong key, low battery)

  ota_cloud_setup.sh ────► the bucket, the read grant, the central IoT policies   (once; again after
                                                                                   a change to it)
  signing_key.sh ────────► the key every image is signed with
  ci/check.sh [--release] ► build all, size + signature checks, the production gate
```

**Where to run them:** from the repository root (`firmware/tools/…`) or from `firmware/`
(`tools/…`) — every script finds its own folder.

---

## 1. Before anything

| Need | For | How |
|---|---|---|
| ESP-IDF **v5.5.2** | every build | `source ~/.espressif/tools/activate_idf_v5.5.2.sh`. `build.sh`, `ota_release.sh` and `ci/check.sh` do it themselves when `IDF_PATH` is not set; `ota_images.sh`, `ota_test_images.sh` and `signing_key.sh` need it set first |
| The **signing key** | every build | `~/.sempreiot/keys/sempreiot_dev_signing_key.pem`, or the path in `SIOT_SIGNING_KEY`. No key = the build stops. `tools/signing_key.sh status` says which key is in use |
| An **AWS login** | `ota_release.sh`, `ota_cloud_setup.sh` | `aws login` (account 644439356850, `us-east-1`). Check: `aws sts get-caller-identity` |
| The **cloud set up** | `ota_release.sh` (real publish) | `firmware/tools/ota_cloud_setup.sh` once (§6) |

**Never two builds at the same time:** two `idf.py` runs share the component cache and break each
other. Run the scripts one after another.

---

## 2. `tools/ota_release.sh` — build a version and publish it to the Internet

```
tools/ota_release.sh <version>                    build board, node and leaf at <version>, publish them
tools/ota_release.sh --bump [patch|minor|major]   the same, at the next version after the highest published
tools/ota_release.sh --list                       what is published
tools/ota_release.sh --remove <version>           unpublish a version (units already on it keep it)
```

### 2.1 Parameters

| Parameter | Value | Default | What it does |
|---|---|---|---|
| `<version>` | `MAJOR.MINOR.PATCH[-PRE]`, e.g. `0.3.4`, `0.4.0-rc1` (≤ 24 chars) | — | The version to build and publish. It is written into every image (`esp_app_desc_t.version`). Give a version **or** `--bump`, not both |
| `--bump` | `patch` \| `minor` \| `major` | `patch` | Takes the **highest published** version of the catalog (of that central with `--central`) and adds one: `0.3.3` → `0.3.4` (patch), `0.4.0` (minor), `1.0.0` (major). After a pre-release, `patch` gives its release: `0.4.0-dev` → `0.4.0`. Refused when nothing is published yet (give the first version by hand) |
| `--list` | — | — | Prints the published versions, newest first: date, sizes, who published, notes |
| `--remove` | `<version>` | — | Rewrites the catalog without it, deletes its S3 folder, announces the new catalog. Units that run it keep running it; centrals stop offering it |
| `--central` | the central's **Identity ID** (`us-east-1:xxxxxxxx-…`) | — (= every central) | A release for **one central only**. Works with every action above (publish, `--bump`, `--list`, `--remove`). The ID is checked in the `Device` table first; a Sub ID, a name or an unknown ID is refused. See §2.4 |
| `--notes` | text | empty | Shown on the tablet and the phone beside the version ("Firmwares no tablet", the update sheet) |
| `--channel` | `bench` \| `stable` | `bench` | The folder and topic the release goes to. `stable` refuses a pre-release version and the development key. Only `bench` exists in practice today (`before-production.md` item 9) |
| `--flash` | `4mb` \| `8mb` | `8mb` | Board image only: flash size, as `ota_images.sh`. Node and leaf are always 4 MB |
| `--no-build` | — | — | Publishes the images already in `firmware/out/ota/<version>/` (each signature is verified). For a version built earlier, e.g. by `ota_images.sh` |
| `--replace` | — | — | Allows publishing a version that is already published. The new images replace the old ones; tablets see the new hash and download them again |
| `--dry-run` | — | — | Builds and checks, writes `manifest.json` and `catalog.dry-run.json` into `firmware/out/ota/<version>/`, uploads nothing. Works before the bucket exists |
| `-h`, `--help` | — | — | The usage text |

| Environment | Default | What |
|---|---|---|
| `SIOT_RELEASE_BUCKET` | `sempreiot-releases` | The S3 bucket |
| `SIOT_RELEASE_REGION` | `us-east-1` | Its region |
| `SIOT_DEVICE_TABLE` | `Device` | The DynamoDB table the centrals were registered in (`--central` check) |
| `SIOT_SIGNING_KEY` | `~/.sempreiot/keys/sempreiot_dev_signing_key.pem` | The signing key (used by the build) |
| `IDF_ACTIVATE` | `~/.espressif/tools/activate_idf_v5.5.2.sh` | Where to find ESP-IDF when `IDF_PATH` is not set |

### 2.2 What it does, in order

1. **AWS:** checks the login, finds the central (`--central`), the bucket, and reads the catalog.
   A catalog that exists but cannot be read stops everything (writing over it would lose the
   history).
2. **Version:** `--bump` computes it. Already published → refused unless `--replace`. **Older than
   the highest published → allowed**, with a note: it is published for going back on purpose and is
   never offered as an update.
3. **Build and sign:** `ota_images.sh <version> --jump` (skipped with `--no-build`).
4. **Check each image as the tablet will:** magic `0xABCD5432`, the version inside equals
   `<version>`, `project_name` is `sempreiot-<family>` (a node image named as the board's is
   refused). Size and SHA-256 are recorded.
5. **Who published it:** git user and e-mail, the AWS identity, the machine (`hostname -s`), the
   commit (`+dirty` when the firmware tree had uncommitted changes).
6. **Upload:** the three `.bin`, then `manifest.json`, then `catalog.json` — the catalog is the write
   that publishes.
7. **Announce:** the catalog, retained, on MQTT (§5.2). Every central hears it at its next connect,
   or at once if it is connected.

### 2.3 Output

```
release 0.3.4 (s3://sempreiot-releases/bench):
  by tallesaugusto <…> on MacBook-Pro, commit 4706fbb, AWS arn:aws:iam::644439356850:root
  board    987136 B  sha256 31d7055c59fca47a…  bench/0.3.4/board-0.3.4.bin
  node    1052672 B  sha256 b82799a4e12fa0f0…  bench/0.3.4/node-0.3.4.bin
  leaf     921600 B  sha256 d84e94902f633094…  bench/0.3.4/leaf-0.3.4.bin
announced on sempreiot/releases/bench (retained)

published: s3://sempreiot-releases/bench/0.3.4/
  0.3.4          2026-10-05T16:15:13Z  board 964 KB  node 1028 KB  leaf 900 KB  by tallesaugusto  …
```

Locally, `firmware/out/ota/<version>/` keeps the three images and `manifest.json`.

### 2.4 A release for one central

```
tools/ota_release.sh 0.3.5 --central us-east-1:960b9435-b2c7-cad9-8b3e-4ed338720e14 --notes "fix for this site"
tools/ota_release.sh --list --central us-east-1:960b9435-b2c7-cad9-8b3e-4ed338720e14
tools/ota_release.sh --remove 0.3.5 --central us-east-1:960b9435-b2c7-cad9-8b3e-4ed338720e14
```

- **The Identity ID** is on the tablet: "QR da Central" → _Identity ID_. It is the ID AWS uses for
  that central's folder and topic, so it is the one the script takes.
- **Where it goes:** `s3://sempreiot-releases/centrals/<Identity ID>/<channel>/<version>/` and the
  retained topic `<Identity ID>/release`.
- **Who sees it:**
  - Only that central hears it. Its tablet merges it with the catalog for everyone, and the version
    shows **SÓ ESTA CENTRAL**.
  - Only that central can read the folder (the S3 grant names each central's own folder).
- **The same version in both catalogs:** the one made for the central wins.
- **Finding the Identity ID from a central's login name** (`central-003@sempreiot.com`), read-only:
  ```
  SUB=$(aws cognito-idp admin-get-user --user-pool-id us-east-1_t6mTbVcqB \
        --username central-003@sempreiot.com --query "UserAttributes[?Name=='sub'].Value" --output text)
  aws dynamodb get-item --table-name Device --key "{\"subId\":{\"S\":\"$SUB\"}}" \
        --query 'Item.[name.S,identityId.S]' --output text
  ```
  On 2026-10-05: `central-003` = `us-east-1:960b9435-b2c7-cad9-8b3e-4ed338720e14`,
  `central-002` = `us-east-1:960b9435-b271-c27e-0781-73fe64baa097`.

### 2.5 Errors and what they mean

| Message | Meaning / what to do |
|---|---|
| `AWS credentials do not work: run 'aws login' first` | The login expired or was never made |
| `bucket sempreiot-releases not found …: run tools/ota_cloud_setup.sh first` | The cloud is not set up (a `--dry-run` still works) |
| `cannot read s3://…/catalog.json: …` | The catalog exists but could not be read (network, permission). Nothing was changed |
| `<v> is already published on …: --replace to publish it again` | Choose another version, or `--replace` |
| `note: <v> is OLDER than <highest>` | Not an error: published for going back on purpose, never shown as an update |
| `'<x>' is not an Identity ID` / `no central with Identity ID '<x>'` | `--central` needs the Identity ID, and it must be in the `Device` table |
| `nothing is published yet: give the first version by hand` | `--bump` has nothing to add one to |
| `the image says version 'X', not 'Y'` / `the image is 'sempreiot-node', not 'sempreiot-board'` | A wrong file in `out/ota/<v>/` (`--no-build`): rebuild |
| `… is NOT signed with the key in use` | Built with another key, or unsigned: rebuild with the key in use |
| `stable takes no pre-release` / `stable is never signed with the development key` | The production channel's rules |
| `the catalog is … B, over the 120000 B an MQTT message may carry` | About 200 versions published: `--remove` old ones |

---

## 3. `tools/ota_images.sh` — the three signed images of one version (Manual)

```
tools/ota_images.sh <version> [--flash 4mb|8mb] [--jump]
```

| Parameter | Default | What it does |
|---|---|---|
| `<version>` | — | `MAJOR.MINOR.PATCH[-PRE]` |
| `--flash` | `8mb` | Board flash size (`8mb` product, `4mb` bench devkits) |
| `--jump` | off | Skips the typo guard below |

- **Typo guard:** the version must be the next one after the **last folder built** in
  `firmware/out/ota/` (by date): next patch, next minor (`.0`) or next major (`.0.0`). It was added
  after `2.2.5` was built for `0.2.5` (2026-10-02). `ota_release.sh` passes `--jump`, because there
  the published catalog is the record.
- **Builds** each app from scratch in `apps/<app>/build-ota` (`SIOT_VERSION=<version>`; the normal
  `build*` directories are not touched).
- **Output:** `firmware/out/ota/<version>/{board,node,leaf}-<version>.bin`. It prints size and a short
  SHA-256 and verifies each signature against the key in use. `firmware/out/` is not in git.
- **Manual use:** copy the files to the tablet, then "Atualizar dispositivos" → **Manual** →
  "Procurar no tablet".

---

## 4. `tools/ota_test_images.sh` — images for the bench checks

```
tools/ota_test_images.sh <version> [--flash 4mb|8mb]
```

`<next>` is `<version>` with the patch + 1. Output in `firmware/out/ota-test/<version>/`:

| File | What it is for |
|---|---|
| `board-<v>.bin`, `node-<v>.bin`, `leaf-<v>.bin` | good images |
| `board/node/leaf-<next>-selftest-fail.bin` | never confirm themselves → the unit rolls back (O4) |
| `leaf-<next>-lowbat.bin` | mock battery 40 % → the next offer is refused (O13) |
| `board-<v>-UNSIGNED.bin` | no signature → refused (O1) |
| `board-<v>-WRONGKEY.bin` | signed with a throw-away key (deleted afterwards) → refused (O1) |

There is no typo guard here. These are bench files: **never publish them** with `ota_release.sh`
(it only takes `out/ota/`, and would refuse a wrong version or project anyway).

---

## 5. Where things are (cloud)

### 5.1 S3: `s3://sempreiot-releases/`

```
bench/
  catalog.json                                 every published version, newest first
  0.3.3/board-0.3.3.bin  node-0.3.3.bin  leaf-0.3.3.bin  manifest.json
  0.3.4/…
centrals/
  us-east-1:960b9435-…/                        one central's own releases
    bench/
      catalog.json
      0.3.5/board-0.3.5.bin  node-0.3.5.bin  leaf-0.3.5.bin  manifest.json
```

The bucket is private (public access blocked), versioned (an overwritten or deleted object can be
recovered) and encrypted.

```
aws s3 ls --recursive s3://sempreiot-releases/                 # everything
aws s3 cp s3://sempreiot-releases/bench/catalog.json - | python3 -m json.tool
```

### 5.2 MQTT topics (AWS IoT, retained)

| Topic | Who hears it | Payload |
|---|---|---|
| `sempreiot/releases/<channel>` | every central | the catalog |
| `<Identity ID>/release` | that central only | its own catalog |

Read what a central gets when it connects:

```
EP=$(aws iot describe-endpoint --endpoint-type iot:Data-ATS --query endpointAddress --output text)
aws iot-data get-retained-message --endpoint-url https://$EP --topic sempreiot/releases/bench \
  --query payload --output text | base64 -d | python3 -m json.tool
```

### 5.3 The catalog (`catalog.json` = the retained payload)

```json
{
 "v": 1, "channel": "bench", "bucket": "sempreiot-releases", "region": "us-east-1",
 "central": {"subId": "…", "identityId": "us-east-1:…", "name": "Bloco A Central"},
 "updated": "2026-10-05T16:15:13Z",
 "releases": [
  {"version": "0.3.4", "published": "2026-10-05T16:15:13Z", "notes": "…",
   "published_by": {"who": "tallesaugusto", "email": "…", "aws": "arn:aws:iam::…:root",
                    "host": "MacBook-Pro", "commit": "4706fbb"},
   "images": {
     "board": {"key": "bench/0.3.4/board-0.3.4.bin", "size": 987136, "sha256": "…", "project": "sempreiot-board"},
     "node":  {"key": "…", "size": …, "sha256": "…", "project": "sempreiot-node"},
     "leaf":  {"key": "…", "size": …, "sha256": "…", "project": "sempreiot-leaf"}}}
 ]
}
```

`central` is there only in a catalog for one central. `manifest.json` in a version folder is that
version's entry plus `channel`, `bucket`, `region` (and `central`).

**What the tablet does with it:**
- It downloads the **highest** version of each family by itself.
- It checks size, SHA-256, family and version; the unit checks the signature.
- A unit below the highest version counts for the badge.
- Older versions are downloaded only when someone picks one.

---

## 6. `tools/ota_cloud_setup.sh` — the cloud side, once

```
tools/ota_cloud_setup.sh            make or update everything
tools/ota_cloud_setup.sh --check    only report, change nothing
```

| Step | What | `--check` reports |
|---|---|---|
| 1 | Bucket `sempreiot-releases`: created; public access blocked; versioning; AES256 encryption | `exists` / `MISSING` |
| 2 | Role `CognitoAuthSigv4AwsIot` (the identity pool's, used by tablets and phones), inline policy `SempreIoTReleasesRead`: `s3:GetObject` on `bench/*`, `stable/*` and `centrals/${cognito-identity.amazonaws.com:sub}/*` (each central only its own folder) | `present` / `OUT OF DATE` / `MISSING` |
| 3 | Every live `Central_*` IoT policy: Subscribe + Receive on `sempreiot/releases/*`. The oldest non-default version is deleted first (AWS keeps 5). New centrals get it from `lambda/central/policies.mjs` | `present` / `MISSING` per policy |
| 4 | The shared user policy `SempreIoTCognitoPolicy`: Publish on `topic/*/cmd/${cognito-identity.amazonaws.com:sub}`, so a phone can ask its central for an Internet update **only under its own Identity ID** (the central reads who asked from the topic). Needed for the phone's Atualizar / Cancelar | `present` / `MISSING` |

| Environment | Default |
|---|---|
| `SIOT_RELEASE_BUCKET` | `sempreiot-releases` |
| `SIOT_RELEASE_REGION` | `us-east-1` |

It can be run again safely. **Run it before installing an app build that needs a new grant:** AWS
IoT drops a central that subscribes outside its policy.

---

## 7. `tools/ota_catalog.py` — the catalog helper

Used by `ota_release.sh`; standard library only. By hand it is useful to inspect files:

| Command | What |
|---|---|
| `ota_catalog.py list <catalog.json>` | the versions, as `--list` prints them |
| `ota_catalog.py highest <catalog.json>` | the highest version |
| `ota_catalog.py bump <catalog.json> patch\|minor\|major` | the next version |
| `ota_catalog.py has <catalog.json> <version>` | exit 0 when published |
| `ota_catalog.py cmp <a> <b>` | `-1` / `0` / `1`, the app's version order (`compareFirmwareVersions`) |
| `ota_catalog.py manifest <dir> <version> <key prefix> <facts.json> <out>` | checks the three images and writes a manifest |
| `ota_catalog.py add <catalog> <manifest> <out>` / `remove <catalog> <version> <out>` | edit a catalog |
| `ota_catalog.py central <dynamodb.json>` / `facts …` / `field <json> <name>` | internals of `ota_release.sh` |

**Version order:** `MAJOR.MINOR.PATCH` compared as numbers. A pre-release sorts before its release
(`0.4.0-dev < 0.4.0`), and pre-releases compare as text. A leading `v` is ignored. Anything that is
not semver sorts before every semver.

---

## 8. `tools/signing_key.sh` — the key

```
tools/signing_key.sh status          which key, present or not, its fingerprint
tools/signing_key.sh new             a NEW key (the old one is kept beside it, dated)
tools/signing_key.sh verify <bin>    is this image signed by the key in use?
tools/signing_key.sh backup <dir>    copy the key to <dir> (mode 600)
```

**A new key means a cable flash of every unit:** a unit only accepts images signed with the key of
the image it runs. Read `docs/ota/signing-key.md` before `new`.

---

## 9. `build.sh` and `ci/check.sh` (for completeness)

```
firmware/build.sh <board|node|leaf|host> [--flash 4mb|8mb | --module n8r8|n4] [--bench] [-- <idf.py args>]
firmware/ci/check.sh [--release]
```

- **`build.sh`:** the everyday build at `firmware/VERSION`, in a variant directory per option
  (`build`, `build-4mb`, `build-4mb-bench`, …). It is flashed by cable with `tools/flash.sh` (same
  flags). `--bench` moves the tablet link to native USB and puts a console on UART0; it is never
  for a unit wired to the tablet.
- **`ci/check.sh`:** builds board, node, leaf and board-4mb, and checks node/leaf ≤ 1.75 MB and every
  signature. It runs the host tests and lists everything relaxed for the bench. **`--release`
  fails** while any item of `before-production.md` is still relaxed (today: the version rule, the
  development key, `-dev` version, PIN once per session, the `bench` channel…).

---

## 10. Recipes

**Publish the next version to every central**
```
firmware/tools/ota_release.sh --bump --notes "what changed"
```

**Publish a version built earlier**
```
firmware/tools/ota_images.sh 0.3.6            # or it already exists in firmware/out/ota/0.3.6/
firmware/tools/ota_release.sh 0.3.6 --no-build --notes "…"
```

**Try without publishing**
```
firmware/tools/ota_release.sh 0.3.6 --dry-run
cat firmware/out/ota/0.3.6/catalog.dry-run.json
```

**Fix a version that was published with a problem**
- Same number: `ota_release.sh 0.3.6 --replace --notes "rebuilt"`. Tablets download the new bytes;
  units that already installed the old 0.3.6 are **not** updated again (same version).
- Better: publish `0.3.7`.
- Or withdraw it: `ota_release.sh --remove 0.3.6` (units on it keep it).

**Take units back to an older version**
1. The older version must be published (it usually still is; otherwise
   `ota_release.sh 0.3.3 --no-build`).
2. On the tablet: Internet → select the units → **Atualizar** → pick the older version (it asks
   first).
3. On the bench this works because the version rule is off (`before-production.md` item 1). In
   production a unit refuses an older image.

**A fix for one site only**
```
firmware/tools/ota_release.sh 0.3.6-site1 --central us-east-1:… --notes "temporary fix for site 1"
```

**See who published what**
```
firmware/tools/ota_release.sh --list
firmware/tools/ota_release.sh --list --central us-east-1:…
```
On the tablet: "Firmwares no tablet" → "Publicado por …". The run history (Registro) also says
whether an update came from Internet or Manual, and who published the release.

---

## 11. When something does not show on the tablet

| Symptom | Look at |
|---|---|
| "Aguardando a lista de versões da internet…" stays | The tablet is not connected to AWS IoT (look for `[Central] ✓ MQTT connected` in the log), or its policy lacks the releases grant (`ota_cloud_setup.sh --check`) |
| The version is listed but "Firmwares no tablet" shows a download error | `não encontrado na nuvem (403/404)`: run `ota_cloud_setup.sh` (read grant). `SHA-256`: the S3 object is not what the catalog says (republish with `--replace`) |
| Nothing downloads | Downloads wait while an alarm is held or an update/push runs, and start again when it ends |
| No badge | No unit the tablet hears runs less than the highest published version, or an update is running |
| A version for one central does not appear | `--central` must be that tablet's Identity ID ("QR da Central"); check with `--list --central …` |

Log lines on the tablet (`flutter run` console): `[OTA] catalog bench: 0.3.4, 0.3.3`,
`[OTA] node-0.3.4 downloaded (… B)`, `[OTA] node-0.3.4: <why it failed>`.
