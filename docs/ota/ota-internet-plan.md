# OTA through the Internet — releases on S3, "Internet" beside "Manual" (plan v1)

_Started 2026-10-05. Status: **steps 1–2 done** (the bucket, the grants and the first release 0.3.3
are live). **Steps 3–5 in code**: the tablet hears the catalogs, downloads the newest images, shows
the badge and the Internet | Manual switch, and runs an Internet update; an Administrador's phone
starts and cancels one. Not run on devices yet. Releases for one central (D11) and "who published / who started"
(D12) were added the same day.** This is step 5 of the OTA brief (`docs/phases-development/phase3-ota-brief.md`: "tag →
CI builds, signs, uploads; tablet lists and downloads releases"), reshaped by the user's request of
2026-10-05. It also fills the `release` gap of the central mirror (`docs/cloud/central-mirror.md`
§4.4).
**How to use the tools (every parameter, recipes, troubleshooting): `docs/ota/ota-tools.md`.**_

**In one paragraph.** `firmware/tools/ota_release.sh` builds and signs a version and uploads it to a
private S3 bucket **organised by version**. It then announces the **catalog** of every published
version on a **retained MQTT topic**: nothing polls, anywhere. Every central hears the catalog as
soon as it is connected and downloads the newest images into "Firmwares no tablet". It then compares
them with the version every unit runs. A unit that runs less than the **highest** published version
has an **update available**, and "Atualizar dispositivos" shows a count badge. The screen gets a
switch **Internet | Manual**:

- **Manual** is today's file import.
- **Internet** offers the published versions: the newest as the update, and older ones to go back
  on purpose.

Either way **the update runs exactly as it does today** (push to the board, one rollout per unit
through the mesh). An Administrador on the phone sees the same badge and the same screen, and may
start **only an Internet update**.

---

## 1. What the user asked (2026-10-05)

1. A script next to the image tools that **builds the .bin of a version, generates the new version
   number when asked, and publishes it to an S3 bucket organised by version**. Publishing a version
   = a new update is available.
2. "Atualizar dispositivos" gets a **switch: MANUAL** (as today, upload files) **and INTERNET** (the
   S3 releases).
3. The app **always compares with each device's version**. Only a **higher** published version is an
   update; **a lower one may be published and installed too** (downgrade), but it is never shown as
   an update.
4. **A badge (rounded circle) on "Atualizar dispositivos"** when there is an update.
5. **The mechanism stays the same.**
6. The same on the **online view** (the phone mirror). **Users may run OTA from Internet updates
   only.**

Item 6 reverses rule 2 of the central mirror ("a firmware update is never started from the cloud —
on site, PIN level 4", decided 2026-10-02/03). That rule is updated with this change. §7 has the
safety rules that replace it.

---

## 2. Decisions

| # | Decision | Why |
|---|---|---|
| D1 | **Storage: one private S3 bucket, `sempreiot-releases`** (us-east-1, name free on 2026-10-05): public access blocked, versioning on, SSE-S3. **Organised by version:** `{channel}/{version}/{board,node,leaf}-{version}.bin` + `{channel}/{version}/manifest.json`, plus `{channel}/catalog.json` (every published version, newest first). | The user's layout. The OTA blueprint §2 already uses this bucket name. Private: only signed-in apps read the images. |
| D2 | **Announcement: the catalog, retained, on `sempreiot/releases/{channel}`.** Published by `ota_release.sh`, never by a phone, never by a central. | The user rejected polling (2026-10-02). A retained message reaches every central at every (re)connect, so a central that was offline catches up by itself. One message holds every version, so a downgrade target is known too. |
| D3 | **Download: the tablet GETs the object from S3, signed with its own identity-pool credentials** (SigV4; `aws_signature_v4` is already in the app). The identity pool's role `CognitoAuthSigv4AwsIot` gets `s3:GetObject` on `sempreiot-releases/*`. The phone never downloads an image. | No new lambda, and no expiring URL inside a retained message. The credentials already exist on the tablet (`central_credentials_service.dart`). |
| D4 | **"Update available" = `compareFirmwareVersions(highest published, unit.fwVersion) > 0`** for a unit of that family (`unitFamily(node)`), not retired. A unit with no known version counts as available. | The user's rule: only higher is an update. It uses the same comparator as the screen (`domain/ota/firmware_version.dart`), and the script orders versions the same way. |
| D5 | **Any published version can be installed through Internet, a lower one too** (downgrade), with the same confirmation Manual asks for an older version. Only the **highest** is preselected and badged. A version that is not in the catalog can never be installed through Internet. | User, 2026-10-05: "it allows you to downgrade too, but it only looks as update for higher versions". |
| D6 | **One mechanism.** An Internet run calls the same `DeviceUpdateController.start / startAll` with the downloaded library entry. Push, `_waitHeld`, `_waitMeshBack`, deepest first, root last, board → nodes → leafs, the history tables: unchanged. | Requirement 5. The only new code before the run is "make sure the image is in the library and matches the catalog". |
| D7 | **A remote start is authenticated by AWS, not by the payload.** The phone publishes on `{centralId}/cmd/{its own Identity ID}`. The shared user policy `SempreIoTCognitoPolicy` allows `topic/*/cmd/${cognito-identity.amazonaws.com:sub}`, so a user can publish only under its own ID, and the central reads who asked from the topic. (Today's `sub` inside the payload is "a label, not a proof".) _Changed during the build, 2026-10-05: one statement in the shared policy instead of a grant in every per-user `Access_*` policy — no lambda change, nothing to update when a user is accepted._ | Starting an update is not Identificar: the central must know who asked, not be told. |
| D8 | **Who may start remotely: Administrador (Nível 4)** on that central, read from the central's own access relations (`centralAccessRelationsProvider`) by `userSubId`. **Decided 2026-10-05.** | Level 4 is the level whose PIN starts an update on site. |
| D9 | **The phone gets the catalog from the central, inside the mirror** (`ota` message), not from its own subscription. | The phone shows what the central knows (the mirror principle), and the user policy does not change. |
| D11 | **A release for one central** (decided 2026-10-05): `ota_release.sh <version> --central <Identity ID>`. The central is named by its **Identity ID** (`us-east-1:xxxxxxxx-…`, shown in "QR da Central"), the ID AWS uses and checks: the S3 folder `centrals/<Identity ID>/<channel>/<version>/` and the retained topic `<Identity ID>/release`. The script looks it up in the `Device` table only to confirm it exists and to print its name, so a typo never publishes to a folder nobody reads. The central already receives `<its id>/*`, so its IoT policy needs no change. The S3 read grant uses `${cognito-identity.amazonaws.com:sub}` (= the Identity ID), so a central can read **only its own** folder. The tablet merges both catalogs; a version made for it shows **SÓ ESTA CENTRAL**. | One ID end to end: what the person types is what AWS stores and enforces (the user chose the Identity ID over the Sub ID, 2026-10-05). Names are not unique (both live centrals are "Bloco A Central"), and `central-003` exists only inside the central's login name. |
| D12 | **Who published, who started.** Every release records `published_by`: git user and e-mail, the AWS identity, the machine, the commit (`+dirty` when the tree had changes). It goes into the catalog, `--list` and "Firmwares no tablet". Who **started** an update is already in the run history and the audit trail: `master` / `admin` (the PIN used on the tablet), and `remote:<name>` for a phone (§5.4). | User, 2026-10-05: "can we track who sent the OTA?" While everybody uses the AWS root login, the AWS identity says `root` for everybody: the git user is the one that names the person. An IAM user per person would make the AWS line meaningful too. |
| D10 | **Channel `bench` only, for now** (decided 2026-10-05: the user fixes it for production). `ota_release.sh` publishes to `bench` by default and the tablet listens to `bench`. It is listed as item 9 of `before-production.md` and in `ci/check.sh --release`. | Today's images are signed with the development key; a `stable` channel for customers comes with the production key. |

---

## 3. The release script — `firmware/tools/ota_release.sh` (written 2026-10-05)

```
tools/ota_release.sh <version>                       build board, node and leaf at <version>, publish
tools/ota_release.sh --bump [patch|minor|major]      the same, at the next version after the highest published
tools/ota_release.sh --list                          what is published
tools/ota_release.sh --remove <version>              unpublish (units already on it keep it)
  options: --notes "text"  --channel bench|stable  --flash 4mb|8mb
           --no-build (publish the images already in firmware/out/ota/<version>/)
           --replace  (publish a version again)  --dry-run (build and check, upload nothing)
```

Helper: `firmware/tools/ota_catalog.py` (header check, version order, catalog edits; standard
library only).

### 3.1 What it does, in order

1. **Preflight.** It sources IDF 5.5.2 when needed and checks the AWS login
   (`sts get-caller-identity`), the bucket, and the catalog. A catalog that cannot be read stops
   everything, because writing over it would lose the history. `stable` refuses a pre-release
   version and the development key, as `ci/check.sh --release` does.
2. **Version.** `--bump` takes the highest published version and adds one. After a pre-release, the
   next patch is its release: `0.4.0-dev` → `0.4.0`. **Any version may be published.** An older one
   prints "published for going back on purpose; it is not offered as an update". A version that is
   already published needs `--replace`: the tablets see a new hash and download it again.
3. **Build and sign** with `ota_images.sh <version> --jump`: the published catalog is the version
   record now, not the last local folder. Images go to `firmware/out/ota/<version>/` as before, each
   verified against the key in use. `--no-build` takes them from there instead.
4. **Check each image as the tablet will** (`firmware_image.dart`): magic `0xABCD5432`; `version`
   at offset 48 must equal `<version>`; `project_name` at 80 must be `sempreiot-<family>`. A node
   image named as the board's is refused. Size and SHA-256 go into `manifest.json`.
5. **Upload** in this order: the three `.bin`, then `manifest.json`, then `catalog.json`. The
   catalog is the write that publishes.
6. **Announce** the catalog, retained:
   `aws iot-data publish --topic sempreiot/releases/{channel} --qos 1 --retain`.

`--remove` rewrites the catalog first, then deletes `{channel}/{version}/`, then announces.
Centrals stop offering that version; units already on it stay on it.

### 3.1b A release for one central

```
tools/ota_release.sh 0.3.5 --central us-east-1:960b9435-b271-c27e-0781-73fe64baa097 --notes "fix for Bloco A"
tools/ota_release.sh --list --central us-east-1:960b9435-b271-c27e-0781-73fe64baa097
```

The script checks that the Identity ID is in the `Device` table and prints the central's name. It
then works exactly as above, under `centrals/<Identity ID>/<channel>/`, and announces on
`<Identity ID>/release`. A Sub ID or a name is refused: names are not unique.

### 3.2 Catalog (= `catalog.json` = the retained payload)

```json
{
 "v": 1, "channel": "bench", "bucket": "sempreiot-releases", "region": "us-east-1",
 "updated": "2026-10-05T16:09:46Z",
 "releases": [
  {"version": "0.3.4", "published": "2026-10-05T16:09:46Z", "notes": "Leaf: new parent on the same wake",
   "published_by": {"who": "tallesaugusto", "email": "…", "aws": "arn:aws:iam::644439356850:root",
                    "host": "MacBook-Pro", "commit": "4706fbb"},
   "images": {
     "board": {"key": "bench/0.3.4/board-0.3.4.bin", "size": 987136, "sha256": "31d7…", "project": "sempreiot-board"},
     "node":  {"key": "bench/0.3.4/node-0.3.4.bin",  "size": 1052672, "sha256": "b827…", "project": "sempreiot-node"},
     "leaf":  {"key": "bench/0.3.4/leaf-0.3.4.bin",  "size": 921600,  "sha256": "d84e…", "project": "sempreiot-leaf"}}},
  {"version": "0.3.3", "...": "..."}
 ]
}
```

`manifest.json` in a version folder is that version's entry, plus channel, bucket and region. One
version is about 0.6 KB of catalog. MQTT carries up to 128 KB, and the script refuses beyond
120 KB, so `--remove` old versions after a couple of hundred.

The tablet trusts nothing in it blindly. The downloaded file must hash to `sha256`, and its header
must say `project` and `version`. The units still verify the signature, as today (§13.1).

### 3.3 Tested 2026-10-05 (nothing uploaded)

- A dry run on the 0.3.3 images: header check, sizes, hashes, manifest and catalog written.
- The catalog helper:
  - ordering `0.4.0-dev > 0.3.10 > 0.3.3`
  - `--bump` (`0.3.9` → `0.3.10`; `0.4.0-dev` → `0.4.0`)
  - "already published"
  - remove
  - refusing a missing image and a node image named as the board's

---

## 4. Cloud setup — `firmware/tools/ota_cloud_setup.sh` (written 2026-10-05, not run yet)

Live AWS changes are made by the user, with their own login. The script can be run again safely:
each step checks first, and `--check` only reports.

1. **Bucket** `sempreiot-releases`: created, public access blocked, versioning, default encryption.
2. **Role** `CognitoAuthSigv4AwsIot`: inline policy `SempreIoTReleasesRead` = `s3:GetObject` on
   `sempreiot-releases/bench/*`, `…/stable/*` and `…/centrals/${cognito-identity.amazonaws.com:sub}/*`
   (D11). Phones and centrals share this role. The channel images are signed, and firmware is not a
   secret, so this is accepted; a central's own folder is its own.
3. **Every live `Central_*` IoT policy**: Subscribe `topicfilter/sempreiot/releases/*` and Receive
   `topic/sempreiot/releases/*`, added as two statements. Both policies sit at the 5-version limit,
   so the oldest non-default version is deleted first. **`lambda/central/policies.mjs` already has
   the same grant** for new centrals (2026-10-05).
4. **The shared user policy `SempreIoTCognitoPolicy`**: Publish on
   `topic/*/cmd/${cognito-identity.amazonaws.com:sub}` (D7). This policy exists only in AWS
   (`lambda/user` attaches it by name), so the script patches the live one.

Run by the user on 2026-10-05: the bucket was created, the role grant added, and
`Central_central-003` (v10) and `Central_central-002` (v9) updated. The per-central read grant (D11)
came after that run; `--check` reports it as **OUT OF DATE** until the script is run again.

**Order: the policies go live before the app build that uses them.** A central that subscribes
outside its policy has its connection dropped (central-mirror §7).

---

## 5. The app — tablet

### 5.1 The catalog and the downloads — in code 2026-10-05

Files:
- `domain/ota/firmware_release.dart`: the catalog, its parse (never throws), the merge, the highest
  version.
- `data/services/release_downloader.dart`: the SigV4 GET from S3, with the central's credentials
  (`centralCredentialsServiceProvider`, now shared with the MQTT session).
- `application/firmware_release_provider.dart`: the topics, the state, the automatic download,
  `ensureImage` (step 4 uses it for older versions), and `firmwareReleaseSyncProvider`, which
  MainScreen keeps alive.
- "Firmwares no tablet" tags each file **INTERNET**, **SÓ ESTA CENTRAL** or **IMPORTADO**. It shows
  "Publicado por … em …" and the notes, and lists downloads in progress or failed.
- Tests: `test/ota/firmware_release_test.dart`.


- **`firmwareReleasesProvider`** (new, `application/firmware_release_provider.dart`) subscribes to
  `sempreiot/releases/{channel}` on the central's MQTT connection and keeps the catalog in memory.
  Because the message is retained, it is filled at every connect. The subscription goes beside `{id}`
  and `{id}/access` in `central_iot_provider.dart:111`.
- **Automatic download of the newest version** of each family (decided 2026-10-05).
  - When the highest version is not in the library, or is there with another hash, the tablet
    downloads it in the background. `ReleaseDownloader` does a SigV4 GET, then checks the SHA-256
    and the header against the catalog.
  - The image is saved through the existing `FirmwareLibraryStore.save` (`<family>-<version>.bin`,
    atomic `.part`).
  - Older versions are downloaded only when one is chosen.
  - A failure retries at the next connect, and again when an Internet update is started.
  - Never during an alarm, and never while a push or a rollout runs: the serial link and the CPU
    belong to the fire path.
- **"Firmwares no tablet"** shows where each image came from: _Internet_ or _Importado_. An entry
  is "Internet" when its hash matches the catalog. A manual import of the same version with another
  hash shows as Importado and is never used by an Internet run.

### 5.2 The badge — in code 2026-10-05

`application/device_update_source.dart`: `updatesAvailableProvider` and `computeUpdatesAvailable`.
They count the units the tablet hears now (the board always): the same units "Atualizar tudo"
takes, so the badge never counts a unit that nothing can update now. The provider also holds the
remembered Internet | Manual choice (Drift meta `ota_update_source`).


- **`updatesAvailableProvider`** (new) goes through every unit of `topologyProvider`: family →
  highest published → D4. It returns the count of units with an update and, per family, the version.
- **Where the round badge appears** (a pill like `_AcessosDrawerItem`, `main_drawer.dart:551`):
  - the drawer item "Atualizar dispositivos" (tablet `:203`, phone `:131`), with the count;
  - a small dot on the hamburger button (`_BarIconButton`, `main_app_bar.dart:263`), so it is seen
    with the drawer closed;
  - the Internet tab of the screen: "3 dispositivos podem ser atualizados para 0.3.4".
- There is no badge while an update runs; the run line already says so. A published version that
  is lower than what the units run never makes a badge.

### 5.3 The switch in "Atualizar dispositivos" — in code 2026-10-05

As built: the switch sits at the start of the bar, before the Central / Nodes / Leafs chips. The
Internet bar says what is published: "Aguardando a lista de versões da internet…", "Nenhuma versão
publicada", "5 dispositivos com atualização para v0.3.4", or "Tudo na versão mais nova publicada".
The update sheet lists the published versions. Each one says "no tablet" / "na internet" / "só esta
central", who published it and its notes; there is no "Procurar no tablet". "Outra versão…" is
simply the same list: any published version can be chosen, and an older one asks first, as in
Manual. The phone part (§6) is step 5.


A segmented control at the top of `DeviceUpdateBar`: **Internet | Manual**. The tablet remembers the
last choice; the phone has only Internet.

- **Internet.**
  - The highest published version per family heads the bar, with its notes and date, plus the
    units that are behind.
  - "Atualizar tudo" and "Atualizar" (the map selection) take **the highest version**.
  - "Outra versão…" opens the same version sheet as Manual, listing **the published versions
    only**. Older and reinstall ask first, exactly as in Manual.
    - A unit takes an older image only while the version rule is off
      (`before-production.md` item 1). In production it refuses `NOT_NEWER`. Downgrade in
      production is the open product decision "option B" of the OTA step 3 notes.
  - Before the run starts, the image is made present and verified (§5.1). While it downloads, the
    bar shows "Baixando firmware…"; the run starts when the image is ready.
  - With nothing published: "Nenhuma versão publicada".
- **Manual.** Exactly today's bar: the library, "Procurar no tablet", the version sheet, FORCE in
  debug.
- **The same gates apply to both:** the Master / Nível 4 PIN (`ensureOtaPin`) and `_startBlocker`
  (a run, a push, a rollout, an active alarm).
- **History:** `OtaRuns` gets a `source` column (`manual` | `internet`) and the `by` of a remote
  start (`remote:<name>`). This is schema v12, and reference §3.6.1 is updated in the same change.

### 5.4 The remote start, on the tablet — in code 2026-10-05

As built (`application/remote_ota.dart`, `central_mirror_publisher.dart` `onUserCommand`;
protocol in `docs/cloud/central-mirror.md` §4.6):
- The central subscribes to `{id}/cmd/+` and reads the user's Identity ID from the topic.
- Check 2 below (the user is watching) is not required to start. Only a watching phone receives
  the answer, which it always is, since the request comes from the open screen.
- `ota_start` with `all` = "Atualizar tudo" at the highest published version. A family at a version
  needs the units to be ones the central knows.
- When every chosen unit already runs that version, the request counts as Reinstalar.
- Audit actions: `ota_remote_started`, `ota_remote_cancelled`, `ota_remote_refused` (with the
  reason).


`central_mirror_publisher.dart` gets a handler for `{id}/cmd/+`; central-mirror §3.3 is the model.
The command is `{"v":1,"type":"ota_start","family":"node","version":"0.3.4","units":"all"|[mac…]}`.
The tablet carries it out **only if every check passes**:

1. The topic's `userSubId` is a user with access to this central at **Nível 4** (D8).
2. That user is watching (the same rule as Identificar).
3. `version` is **in the published catalog** for that family (D5). It is never a Manual-only file.
4. `_startBlocker` is clear: no run, no push, no rollout, **no alarm held**.
5. The image is in the library and matches the catalog; it is downloaded first if not.

The tablet then calls the same `start` / `startAll` with `by: remote:<name>`. The answer goes back
as an event on `{id}/frames`: `otaStartAccepted`, or `otaStartRefused` plus the reason, in
Portuguese for the phone.

On the tablet, a banner stays up for the whole run: **"Atualização iniciada remotamente por
<name>"**. The tablet can pause or cancel at any time without a PIN, as today.

**A remote cancel** (decided 2026-10-05) is `{"type":"ota_cancel"}`, under the same checks 1–2. It
only stops a run; it is the same Cancelar as the tablet's. There is no remote pause.

---

## 6. The app — phone (online view) — in code 2026-10-05

As built: `mirrorCanUpdateProvider` says whether the account is an Administrador or Master of the
viewed central (from the saved centrals; the central checks again). `firmwareReleasesViewProvider`
and `updatesAvailableProvider` read the central's catalog and count from the mirror. The update
sheet sends `sendOtaStart` instead of starting a run, and asks for no PIN. The drawer badge on the
phone shows the central's count.


- **The `ota` mirror message carries the central's catalog** (versions, notes, dates) and its
  `updatesAvailable` count. The phone's badge, drawer item and Internet tab are fed from it, with
  the same widgets.
- **The phone's bar is the Internet tab only.** There is no Manual tab, no "Firmwares no tablet",
  and no file import.
  - An Administrador sees "Atualizar tudo", "Atualizar" and "Outra versão…" (published versions
    only), and "Cancelar" while a run goes.
  - Everyone else sees today's "As atualizações são iniciadas na central." plus what is available.
- Tapping "Atualizar" asks for confirmation: "A central vai atualizar N dispositivos para 0.3.4. Os
  dispositivos reiniciam durante a atualização." For an older version, the older-version warning
  appears as well.
  - The phone then publishes `ota_start` on `{id}/cmd/{mySub}`.
  - It waits as Identificar does: 6 s for an answer. The run then shows through the mirror
    (`run`/`push`, as today).
- The phone shows the badge **only inside a central**, never on the Centrais list (decided
  2026-10-05, §11 Q4).

---

## 7. Safety rules (they replace central-mirror rule 2 for updates)

1. **Published only.** From the cloud, a unit can only be moved to a version in the catalog: no
   file that was not published, and no FORCE.
2. **Never over an alarm.** A held alarm refuses the start. An alarm during the run behaves as
   today, under the run's existing stop rules.
3. **The site always wins.** The tablet shows who started the run and can pause or cancel it at
   any moment.
4. **AWS proves who asked** (D7), and that user must be an Administrador on that central (D8).
   Every remote start, cancel and refusal goes into the audit trail.
5. **Every image is verified three times:**
   - the catalog hash, on the tablet;
   - the header (family and version), on the tablet;
   - the signature, on the unit.
6. **Publishing is a deliberate act.** Only `ota_release.sh` publishes, run by a person with AWS
   rights. The phone and the central never publish a release.

---

## 8. What does not change

- The SAFR wire (§13 push, rollout, results): **no protocol change**.
- The firmware of the board, node and leaf: **no change**.
- The LED language: nothing new lights.
- The run: `DeviceUpdateController` phases, order, waits, history.
- Manual mode, the library folder, the import.

---

## 9. Steps (each ends with something seen working)

| Step | What | Exit |
|---|---|---|
| **1** | `ota_cloud_setup.sh` — **done 2026-10-05** (run again for the per-central grant, D11). | `ota_cloud_setup.sh --check` reports everything present. |
| **2** | `ota_release.sh` + `ota_catalog.py` — **done 2026-10-05**: 0.3.3 published; `--central` dry run tested. | `ota_release.sh 0.3.4 --notes …` puts three images + a manifest under `bench/0.3.4/`. `--list` shows it, and `aws iot-data get-retained-message --topic sempreiot/releases/bench` returns the catalog. |
| **3** | Tablet: catalog provider, downloader, library source tag, the catalog for one central. Tests with fake MQTT and fake S3. **In code 2026-10-05, 12 tests; not run on a tablet yet.** | The tablet connects and the newest images appear in "Firmwares no tablet" as _Internet_, with hashes checked. |
| **4** | Tablet: badge, the Internet / Manual switch, the Internet run, `OtaRuns.source` + `publishedBy` (schema v12). Tests. **In code 2026-10-05** (controller 4, badge 4, screen 6 new tests; 578 in all pass); not run on a tablet yet. | The badge counts the units behind. "Atualizar tudo" in Internet updates the bench to 0.3.4 by the same steps as Manual. Going back to 0.3.3 through "Outra versão…" works on the bench. |
| **5** | Mirror and remote start: the catalog in `ota`; the phone badge and Internet-only bar; the shared user policy (§4.4); `{id}/cmd/{user}` with `ota_start` / `ota_cancel`; the tablet banner; audit. Tests. **In code 2026-10-05** (19 new tests; 597 in all pass); not run on devices yet. Needs `ota_cloud_setup.sh` step 4. | An Administrador's phone starts an update and can cancel it. A non-admin is refused, and so is a start during a held alarm. The tablet shows who started it. |
| **6** | Docs (§10). | The docs say what the code does. |

## 10. Docs updated with the change

- `docs/cloud/central-mirror.md`:
  - rule 2 (the exception for Internet updates);
  - the §2 topic table (`sempreiot/releases/{channel}`, `{id}/cmd/{sub}`);
  - §3.3;
  - §4.3 (`ota` carries the catalog);
  - §4.4 (built: this page);
  - §7.
- `docs/ota/ota-and-production-blueprint-v1.md` §2 / §3.1: points here. The catalog replaces the
  per-release manifest of the blueprint.
- `docs/phases-development/phase3-ota-brief.md`, step 5: status.
- `docs/sempreiot-system-reference.md`: the OTA rows, row 6.7, and §3.6.1 (`OtaRuns.source`).
- `docs/others/app-sempreiot-central.md`: the update screen, and cloud §6.
- `firmware/tools/` usage in `docs/ota/signing-key.md` / the README: `ota_release.sh` beside
  `ota_images.sh`.

## 11. Questions

| # | Question | Answer |
|---|---|---|
| Q1 | Who may start an Internet update from the phone? | **Administrador (Nível 4)** — decided 2026-10-05. |
| Q2 | May the phone also stop a run? | **Cancelar yes, Pausar no** — decided 2026-10-05. |
| Q3 | Does the tablet download a new release automatically when it is announced? | **Yes**, the newest of each family — decided 2026-10-05. |
| Q4 | A badge on the phone's Centrais list too? | **Not in v1** — decided 2026-10-05. |
| Q5 | One channel `bench` until production? | **Yes** — decided 2026-10-05; `before-production.md` item 9. |
