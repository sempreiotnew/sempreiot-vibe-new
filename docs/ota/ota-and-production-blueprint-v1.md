# SempreIoT — OTA & Production Blueprint v1

Companion to `docs/others/system-blueprint-v1.md`. That document describes how the network forms and
operates; this one describes **how firmware is built, signed, delivered, installed and traced**,
and how units are **identified and provisioned in the factory**.

Vocabulary is the same: **board** (8 MB, USB to the tablet, raises the SoftAP), **tablet**
(the CENTRAL app), **AC device** (siren, mains detector, GPIO box — Mesh-Lite node, always on),
**battery detector** (ESP-NOW leaf, sleeps), **the code** (installation code), **sticker**
(per-device label with QR).

Everything marked `[VERIFY]` is something to confirm against the real ESP-IDF / Mesh-Lite
version in the repo before implementing.

---

## 0. Decisions this blueprint locks in

| # | Decision | Why |
|---|----------|-----|
| D1 | **Two firmware images only**: `sempreiot-board` and `sempreiot-node`. One node image serves every node type (siren, detector, GPIO…); the node reads its type from factory NVS at boot. | One file to distribute through the mesh, one file to certify per release, no risk of flashing the wrong type. |
| D2 | **The board is the only firmware source on site.** Tablet → board over USB; every node pulls from the board. Nodes never talk to the internet. | Matches the existing rule "internet only for viewing". Works offline. |
| D3 | **Nodes pull over HTTP from the board's SoftAP**, one node at a time, orchestrated by the board. Mesh-Lite's native hop-by-hop OTA is a later optimisation, not v1. | Mesh-Lite gives every node IP connectivity to the board (NAPT through parents), so a plain HTTP GET works from any depth. Simple, debuggable, same path for AC devices and battery detectors. |
| D4 | **Battery detectors: pull on wake.** The parent's check-in reply carries "update available"; the detector joins Wi-Fi briefly, pulls, verifies, reboots, sleeps. | Chosen over chunked ESP-NOW (too slow, too much battery, too much code). |
| D5 | **Every image is signed with one company key; every device verifies before it will boot it.** Signed-apps-only during development, full Secure Boot V2 + flash encryption on production units. | Only SempreIoT firmware can ever run on a SempreIoT device. Required for UL 2900-2-3 style security evaluation. |
| D6 | **Rollback is automatic.** New firmware must pass a self-test and confirm itself within 2 minutes or the bootloader reverts. | A bad release can never brick a site. |
| D7 | **Safety rules override OTA.** No update during alarm, trouble, or low battery; only one node updating at a time; root updated last; the board never loses supervision of a node just because it is updating. | UL 864 expectation: updates must not compromise life-safety functions. |
| D8 | **Identity = eFuse MAC (immutable anchor) + factory serial (human label).** Both written at the factory station, never typed by hand. Sticker is printed by the station. | Zero manual ID creation, zero collisions, survives multi-user / multi-central scenarios. |

---

## 1. Firmware images and partition tables

### 1.1 Node — 4 MB (`partitions_node.csv`)

```
# Name,        Type, SubType,  Offset,   Size
nvs,           data, nvs,      0x9000,   0x6000    # runtime settings (installation, names, counters)
otadata,       data, ota,      0xF000,   0x2000
phy_init,      data, phy,      0x11000,  0x1000
ota_0,         app,  ota_0,    0x20000,  0x1E0000  # 1.875 MB
ota_1,         app,  ota_1,    0x200000, 0x1E0000  # 1.875 MB
nvs_factory,   data, nvs,      0x3E0000, 0x8000    # identity, written once at factory, read-only in firmware
coredump,      data, coredump, 0x3E8000, 0x10000
# 0x3F8000–0x400000 spare (32 KB)
```

Constraint: the node image must stay **≤ 1.75 MB** (CI fails the build above that). Mesh-Lite +
ESP-NOW + HTTP client + mbedTLS fits, but use `-Os`, disable unused IDF components, and keep
logging at INFO in release builds.

### 1.2 Board — 8 MB (`partitions_board.csv`)

```
# Name,        Type, SubType,  Offset,   Size
nvs,           data, nvs,      0x9000,   0x6000
otadata,       data, ota,      0xF000,   0x2000
phy_init,      data, phy,      0x11000,  0x1000
ota_0,         app,  ota_0,    0x20000,  0x200000  # 2 MB
ota_1,         app,  ota_1,    0x220000, 0x200000  # 2 MB
fw_store,      data, fat,      0x420000, 0x300000  # 3 MB: holds node.bin + manifest to serve to the mesh
nvs_factory,   data, nvs,      0x720000, 0x8000
coredump,      data, coredump, 0x728000, 0x10000
# 0x738000–0x800000 spare (~800 KB)
```

`fw_store` is why the board needs 8 MB: it keeps the **node** image (≈1.8 MB) plus the release
manifest, so it can serve all nodes on site without the tablet being involved for each one.
Use FATFS with wear levelling (or LittleFS if already in the project); files:
`/fw/node.bin`, `/fw/manifest.json`, `/fw/rollout.json` (progress, survives board reboot).

The board's **own** new image never goes to `fw_store`; it is written straight into the inactive
OTA slot.

### 1.3 Build configuration (both images)

```
CONFIG_PARTITION_TABLE_CUSTOM=y
CONFIG_BOOTLOADER_APP_ROLLBACK_ENABLE=y
CONFIG_SECURE_SIGNED_APPS_NO_SECURE_BOOT=y           # development / stage 1
CONFIG_SECURE_SIGNED_APPS_RSA_SCHEME=y               # RSA-3072; the only scheme ESP32-S3 supports,
                                                      # no chip-rev gate (that gate is original-ESP32-only)
CONFIG_SECURE_SIGNED_ON_UPDATE_NO_SECURE_BOOT=y
CONFIG_SECURE_BOOT_BUILD_SIGNED_BINARIES=y
CONFIG_SECURE_BOOT_SIGNING_KEY="keys/sempreiot_signing_key.pem"   # path injected by CI
CONFIG_APP_PROJECT_VER_FROM_CONFIG=y
CONFIG_APP_PROJECT_VER="0.0.0-dev"                   # overwritten by CI with the git tag
```

`PROJECT_NAME` is `sempreiot-board` or `sempreiot-node`. Both live in the image header
(`esp_app_desc_t.project_name / version`) and are checked before any install (see §4.3).

Note: `CONFIG_SECURE_SIGNED_ON_BOOT_NO_SECURE_BOOT` is **not** usable on ESP32-S3 — it depends on
the ECDSA-V1 signing scheme, which only exists on the original ESP32. On S3 (RSA-3072-only),
stage 1 verifies signatures on OTA update (`SECURE_SIGNED_ON_UPDATE_NO_SECURE_BOOT`, above) but
not on a directly UART-flashed image — only stage 2's hardware Secure Boot closes that gap. Full
command-by-command reference: `docs/ota/secure-signed-firmware-howto.md`.

---

## 2. Release pipeline (build → sign → publish)

```
git tag v1.4.2
      │
      ▼
CI (GitHub Actions or similar, one job per image)
  1. idf.py set-target esp32s3 && idf.py build         (board, then node)
  2. size check: node.bin ≤ 1.75 MB, board.bin ≤ 1.9 MB
  3. sign: done by the build using the key from CI secrets   (never on a developer machine)
  4. produce manifest.json (below)
  5. upload {board.bin, node.bin, manifest.json} to release storage
     s3://sempreiot-releases/<channel>/v1.4.2/           channel = internal | beta | stable
  6. register release in the cloud DB (lambda): version, channel, sha256s, release notes, date
```

`manifest.json`:

```json
{
  "release": "1.4.2",
  "channel": "beta",
  "protocol": 3,
  "min_compatible_protocol": 2,
  "images": {
    "board": { "file": "board.bin", "size": 1834208, "sha256": "…", "project_name": "sempreiot-board", "min_hw_rev": 2 },
    "node":  { "file": "node.bin",  "size": 1791040, "sha256": "…", "project_name": "sempreiot-node",  "min_hw_rev": 1 }
  },
  "notes": "…"
}
```

Rules:

- **Semantic versioning.** `major` = SAFR/protocol break, `minor` = features, `patch` = fixes.
- **N-1 compatibility.** A board on protocol `N` must fully operate nodes on `N-1`, because a
  site is always mixed for a while during a rollout. Enforce in tests.
- **Channels.** `internal` (your bench) → `beta` (2–3 friendly sites) → `stable` (everyone).
  The tablet only shows releases from its configured channel.
- **Keys.** One `sempreiot_signing_key.pem` (RSA-3072, `espsecure.py generate_signing_key --version 2`).
  Private key lives only in CI secrets / an HSM, with an offline backup. The public key is
  compiled into every bootloader. Losing the private key means no more updates for fielded units:
  treat it as the company's most valuable file.

---

## 3. Delivery flow on site

```
 cloud release storage
        │  (tablet online, or installer app sideload)
        ▼
 ┌──────────┐   USB / SAFR OTA_PUSH   ┌──────────────┐   HTTP GET /fw/node.bin   ┌───────────┐
 │  tablet  │ ──────────────────────▶ │    board     │ ◀──────────────────────── │ AC device │
 │ (CENTRAL)│ ◀────────────────────── │  fw server   │ ────── SAFR OTA_OFFER ──▶ │  (mesh)   │
 └──────────┘   progress / results    │  + scheduler │                           └─────┬─────┘
                                      └──────────────┘                                 │ ESP-NOW
                                            ▲   HTTP GET via parent SoftAP (NAPT)      ▼
                                            └──────────────────────────────────── battery detector
                                                                                   (pull on wake)
```

### 3.1 Step 1 — tablet gets the release

1. Tablet (online) lists releases from the cloud for its channel; user taps *Download*.
   Files are stored locally on the tablet, so the update can be applied later with no internet.
2. Offline alternative: the installer app carries the release files; same local storage.
3. Tablet verifies `sha256` of each file against the manifest before offering it.

### 3.2 Step 2 — tablet pushes to the board (USB, SAFR)

New SAFR messages (USB link, tablet → board):

| Message | Payload | Notes |
|---------|---------|-------|
| `OTA_PUSH_BEGIN` | `image` (`board`/`node`), `size`, `sha256`, `version` | Board opens the target: inactive OTA slot (board) or `/fw/node.bin` in `fw_store` (node). |
| `OTA_PUSH_CHUNK` | `seq`, `data` (4 KB), `crc32` | Board ACKs each chunk; tablet resumes from last ACKed `seq` after a USB hiccup. |
| `OTA_PUSH_END` | — | Board verifies signature + sha256 + `project_name`, replies `OTA_PUSH_RESULT {ok, reason}`. |

Bump the USB baud rate to 921600 for this (1.8 MB ≈ 25 s instead of ≈ 3 min at 115200).

Board-side verification of a staged **node** image in `fw_store`: read the file back and run
`esp_image_verify()` on it (`[VERIFY]` — it verifies signature + checksum on any flash region
given an `esp_partition_pos_t`; if it turns out to require an app partition, copy through the
inactive OTA slot as scratch and verify there). Reject if `project_name != "sempreiot-node"`.

### 3.3 Step 3 — the board updates itself (if a board image was pushed)

1. Board asks the tablet to confirm "site will be unsupervised for ~30 s" and refuses if any
   alarm/trouble is active.
2. `esp_ota_set_boot_partition()` → reboot.
3. New firmware runs the **self-test** (§4.4). On success it calls
   `esp_ota_mark_app_valid_cancel_rollback()`; on failure or 2-minute timeout the bootloader
   reverts. Either way the tablet sees the board come back over USB and reads its version.
4. Mesh nodes reconnect to the SoftAP automatically (Mesh-Lite); board re-learns the tree from
   heartbeats.

**Always update the board first**, then nodes: the board has the USB rescue path and must
understand both the old and new node protocol (N-1 rule).

### 3.4 Step 4 — the board rolls the node image through the mesh

The board runs a **rollout scheduler** with this state machine (persisted in `/fw/rollout.json`):

```
IDLE ──push ok──▶ STAGED ──user "Update all"──▶ ROLLING ──queue empty──▶ DONE
                                                   │                        (or PARTIAL if any
                                                   └─ alarm/trouble ──▶ PAUSED ─▶ ROLLING   failed)
```

Queue order:

1. AC devices that are **not** the current root, one at a time (configurable `max_parallel`, default 1).
2. The root AC device last (its reboot forces re-election; do it once, at the end).
3. Battery detectors: not queued — each is offered the update at its next check-in (§3.5).

Per node, the board sends (mesh, via SAFR):

| Message | Direction | Payload |
|---------|-----------|---------|
| `OTA_OFFER` | board → node | `version`, `size`, `sha256`, `url` (`http://<board-ip>/fw/node.bin`), `deadline_s` |
| `OTA_STATUS` | node → board | `state` (`downloading` / `verifying` / `rebooting` / `selftest`), `percent` |
| `OTA_RESULT` | node → board | `ok`, `reason` (`downgrade`, `busy_alarm`, `low_battery`, `sig_fail`, `selftest_fail`, `http_err`…), `version_now` |

Node behaviour on `OTA_OFFER`:

1. Refuse if `version <= running` (unless the offer is flagged `force`, used only from the bench),
   if in alarm/trouble, or (detector) battery below threshold.
2. `esp_https_ota()` against the URL (plain HTTP: the network is WPA2 and the image is signed;
   TLS adds nothing here and costs RAM). `[VERIFY]` that `esp_https_ota` accepts `http://` with
   `CONFIG_ESP_HTTPS_OTA_ALLOW_HTTP=y`.
3. After the header arrives, check `project_name == "sempreiot-node"` and version before
   continuing (`esp_https_ota_get_img_desc`).
4. `esp_ota_end` verifies the signature automatically → set boot partition → `OTA_STATUS rebooting` → reboot.
5. New firmware: self-test (§4.4) → mark valid → `OTA_RESULT ok`. Failure → rollback → old firmware
   sends `OTA_RESULT selftest_fail`.

Board rules while a node is updating:

- Node is marked **UPDATING** (not TROUBLE) for up to `deadline_s` (default 300 s); after that,
  TROUBLE as usual. This is the only exception to heartbeat supervision.
- If any alarm or trouble appears on site, the scheduler goes **PAUSED** (nodes already
  downloading finish; no new offers).
- A node that fails twice is skipped and shown to the user; the release is not retried on it
  automatically.
- Traffic through the root: one download at a time keeps the mesh responsive; 250 nodes ×
  ~40 s ≈ under 3 h for a full site, which is acceptable for a background task.

### 3.5 Step 5 — battery detectors pull on wake

1. Detector wakes on its normal cycle and sends its ESP-NOW check-in to its parent AC device.
2. The parent's reply carries `fw_available: {version, size, sha256}` if the board has a staged
   image newer than the detector's reported version and the scheduler is not PAUSED.
3. Detector decides (same refuse rules as above, plus `battery ≥ 60 %`). If it accepts:
   - joins the mesh Wi-Fi as a station (SSID/password it already has from provisioning; it
     lands on its parent's SoftAP or the board's, whichever is nearest — either works),
   - HTTP GET `/fw/node.bin` from the board IP (through NAPT if via a parent),
   - verifies, sets boot, reboots, self-tests, marks valid, sends one ESP-NOW `OTA_RESULT`,
     goes back to sleep.
   Budget: ~40–90 s awake, once per release. Report the awake time so the app can show
   battery impact.
4. If the detector cannot join Wi-Fi (parent SoftAP full — Mesh-Lite default max connections
   `[VERIFY]`, or RF issue) it reports `http_err` and tries again at a later wake with backoff
   (next wake, then every 6 h, max 5 attempts).
5. The board tracks detector versions from their heartbeats; the app shows "12 of 40 detectors
   updated" — this can take a day or two and that is expected.

### 3.6 Step 6 — the tablet shows and records everything

- Rollout screen: per-node version, state, last result, time; buttons *Update board*,
  *Update all nodes*, *Pause*, *Retry failed*.
- Every `OTA_RESULT` goes into the event log (local SQLite; synced to the cloud when online) —
  this log is UL evidence that each unit runs the released, signed version.
- Version + image SHA-256 (from `esp_app_desc_t`) are part of every node heartbeat, so the
  tablet can prove what is running, not just what was sent.

---

## 4. Firmware building blocks (node and board)

### 4.1 `fw_identity` component (both)

> **Superseded 2026-09-22** (decision in `docs/phases-development/firmware-phase1-network-brief_3.md` §4.1): the
> partition stays `nvs_factory` (read-only), but the keys are the provisioning contract's `id` + `pop`
> (strings; `pop` is the setup-network password, the `/identify` HMAC key and the envelope HKDF input),
> plus `model`. `serial`/`pair_key` below are not used; `dev_type`/`hw_rev` are added only when the
> firmware needs them. The table is kept for the factory-station fields it still describes.

Reads `nvs_factory` at boot (read-only, namespace `factory`):

| Key | Type | Source |
|-----|------|--------|
| `serial` | string | Factory station (e.g. `SI-D-2609-000123`) |
| `dev_type` | u8 | 1 = smoke detector, 2 = siren, 3 = GPIO, 10 = board … |
| `hw_rev` | u8 | Factory station |
| `mfg_date` | u32 | Unix time |
| `pair_key` | blob 16 | Random per unit; printed in the QR, used to prove the sticker was physically read during provisioning |

Immutable chip identity: `esp_efuse_mac_get_default()` → 6-byte base MAC, unique per chip,
burned by Espressif. This is the **primary key** everywhere (SAFR addressing, cloud DB,
rollout table). The serial is the **human label**. If `nvs_factory` is empty or corrupt the
device boots into a "not provisioned" state (white LED pattern) and refuses to join anything.

### 4.2 `ota_client` component (node) / `ota_server` + `ota_scheduler` components (board)

- `ota_client`: handles `OTA_OFFER`, runs `esp_https_ota`, reports status, owns the self-test
  and the mark-valid / rollback decision. Same code for AC device and battery detector; the
  detector wraps it in its wake cycle.
- `ota_server`: `esp_http_server` on the SoftAP, one route `GET /fw/node.bin` (range requests
  supported for resume, `[VERIFY]` `esp_https_ota` resume support), one route `GET /fw/manifest.json`.
- `ota_scheduler`: queue, state machine, safety gating, persistence in `fw_store`.
- `ota_usb`: the `OTA_PUSH_*` handler on the board.

### 4.3 Image acceptance checks (every install path, no exceptions)

1. Signature valid (automatic via IDF when `CONFIG_SECURE_SIGNED_ON_UPDATE*` is set).
2. `project_name` matches the device's image name (`sempreiot-node` / `sempreiot-board`).
3. `version > running` (semver compare) unless `force` from the bench.
4. `min_hw_rev` from the manifest ≤ device `hw_rev` (board checks before offering).
5. Production only: `secure_version` anti-rollback (`CONFIG_BOOTLOADER_APP_ANTI_ROLLBACK`, eFuse
   counter) so a vulnerable old release can never be re-installed. Enable together with Secure Boot.

### 4.4 Self-test before `esp_ota_mark_app_valid_cancel_rollback()`

Run within the first 120 s of a new image, then decide:

- `nvs_factory` readable, identity intact.
- `nvs` readable, installation settings intact (the code, names, parent info).
- Radio up: AC device joined Mesh-Lite and got an IP; battery detector reached its parent over ESP-NOW.
- One heartbeat sent **and acknowledged** by the board.
- Sensor / output sanity (detector chamber reads plausibly, siren driver reports OK, GPIO reads).
- Version in `esp_app_desc_t` equals the one the board offered.

Any failure → `esp_ota_mark_app_invalid_rollback_and_reboot()`. The old image then reports
`selftest_fail` with the failing check.

---

## 5. Production system (factory station)

Goal: a technician plugs a bare board into a jig and, in under a minute, gets a tested,
provisioned, labelled unit registered in the cloud. Nobody types an ID.

### 5.1 Hardware

- Laptop (or Raspberry Pi) running the **factory station** software.
- Flashing jig: pogo pins on `UART0 TX/RX`, `EN`, `IO0`, `3V3`, `GND`; one jig per PCB variant.
- USB label printer (thermal, e.g. Brother QL / Zebra) for the sticker.
- Barcode scanner (optional, to re-scan the sticker as the last check).

### 5.2 Software (Python, `tools/factory_station/`)

Per unit:

```
1. detect chip        esptool.py chip_id            → base MAC (ESP32-S3 has no chip-revision
                      gate for RSA secure boot, unlike the original ESP32)
2. allocate serial    from a range pre-allocated by the cloud (works offline; range fetched
                      when online): SI-<T>-<YYMM>-<seq>, T = D detector / S siren / G gpio / B board
3. build nvs_factory  nvs_partition_gen.py from a per-unit CSV (serial, dev_type, hw_rev,
                      mfg_date, pair_key = os.urandom(16))
4. flash              bootloader + partition table + otadata + app (release channel = stable)
                      + nvs_factory.bin
                      [production] then: enable Secure Boot V2 + flash encryption (§6)
5. functional test    device boots into TEST mode when it sees a magic string on UART within 3 s:
                      LED RGB, buzzer/siren driver, sensor read, Wi-Fi TX power test,
                      ESP-NOW loopback with the station's reference node, RTC tick.
                      Results returned as JSON over UART.
6. register           POST /manufacturing/units (lambda): {mac, serial, dev_type, hw_rev,
                      fw_version, mfg_date, test_results, station_id}. Queued locally if offline.
7. print sticker      QR = "SI1:<serial>:<mac>:<dev_type>:<pair_key_b64>" + human text:
                      serial, type, MAC last 4. Station refuses to print if step 6 (or its queue) failed.
8. (optional) scan    scanner reads the sticker; station checks it matches → unit goes to the tray.
```

Batch mode: station loops steps 1–8 as boards are inserted; a screen shows count, failures,
serial range remaining.

### 5.3 Why not use the eFuse ID directly on the sticker

The eFuse MAC is exactly the right **immutable, no-work unique ID** — that is why it is the primary
key. But as the user-facing sticker ID it has three problems: 12 hex characters is long to read
out over the phone, it says nothing about type / batch / hardware revision, and it exposes a
radio identifier on the outside of the product. So: **MAC inside, serial outside, both bound
together in the factory DB and in the QR.** No collisions are possible because serials are
allocated from cloud-managed ranges and the MAC is unique by construction.

Optional: burn the serial into eFuse `BLK3` (user block, write-once) so identity survives even a
full flash erase. Only do this if you want it; `nvs_factory` + the cloud record is enough for v1.

### 5.4 How the sticker feeds provisioning (ties to system-blueprint-v1)

During setup the app scans the sticker QR, learns `serial + mac + type + pair_key`, and the
device proves it owns `pair_key` during provisioning. This means a device can only be added by
someone who physically had the sticker — which is what makes "multiple users granted access to
a central" safe later: access is granted per central, and a device belongs to exactly one central,
keyed by MAC.

---

## 6. Security stages

| Stage | When | Config | Effect |
|-------|------|--------|--------|
| 1 — Signed apps | Now, all dev + POC boards | §1.3 as written | Only signed images install; bootloader not protected; boards remain reflashable via USB. |
| 2 — Secure Boot V2 + flash encryption | Pilot / production units, at the factory station | `CONFIG_SECURE_BOOT=y` (V2), `CONFIG_SECURE_FLASH_ENC_ENABLED=y` (release mode), same signing key | eFuses burned on first boot; chip only boots bootloaders signed by your key; flash contents encrypted; JTAG + plain reflash disabled. **Irreversible.** |

Rules for stage 2:

- Same key as stage 1, so a stage-2 unit accepts the same releases.
- ESP32-S3 supports up to **3** independent, revocable Secure Boot V2 key digest slots (eFuse
  `BLOCK_KEY0..5` + key purposes), so key rotation is possible on fielded units if ever needed —
  but revoking a slot is itself irreversible, and revoking all 3 can permanently brick a device.
  Protect the signing key accordingly regardless (HSM, two-person access).
- `nvs_factory` must be flashed encrypted on stage-2 units (station handles it).
- Keep 5–10 stage-1 "golden" boards on the bench forever for debugging.

---

## 7. Implementation order (step by step)

Each phase ends with something you can demonstrate on the bench. Do not start the next before
the previous one's exit test passes.

### Phase 0 — Foundations (repo, CI, identity)  *(1 week)*

1. Repo layout: `firmware/board/`, `firmware/node/`, `firmware/components/{safr,fw_identity,ota_client,ota_server,ota_scheduler,ota_usb}`, `tools/factory_station/`, `docs/`.
2. Partition tables from §1; `PROJECT_NAME` / `PROJECT_VER` wired; size checks.
3. Generate the **development** signing key; commit only its public part is unnecessary (it is
   compiled in) — keep the `.pem` out of git, in CI secrets.
4. Enable stage-1 signing config; flash bootloader + app to all 3 POC boards; confirm an
   **unsigned** image is refused.
5. `fw_identity` component + `nvs_partition_gen` script; hand-write one `nvs_factory` per POC board.
6. Unified node image: node type read from `nvs_factory`, not from a build flag.
   **Exit:** `idf.py build` produces signed board + node images with version from git tag; a
   node boots and logs `serial / type / mac / version`.

### Phase 1 — Board self-update over USB  *(1 week)*

1. `OTA_PUSH_*` in SAFR (tablet side + board side), 4 KB chunks, CRC, resume.
2. Board writes to inactive slot, verifies, reboots, self-test, mark valid.
3. Tablet screen: pick local `.bin`, push, watch progress, see new version reported.
   **Exit:** push a deliberately broken image (self-test fails) → board rolls back by itself and
   the tablet shows `selftest_fail`.

### Phase 2 — Node update through the mesh (AC devices)  *(2 weeks)*

1. `fw_store` on the board; `OTA_PUSH image=node` lands in `/fw/node.bin` and is verified.
2. `ota_server` (HTTP on the SoftAP); confirm a mesh child at depth 2 can `GET` the file.
3. `ota_client` on the node: offer → download → verify → reboot → self-test → result.
4. `ota_scheduler`: queue, one at a time, root last, PAUSED on alarm, UPDATING state, timeouts.
5. Rollout screen on the tablet.
   **Exit:** 2 AC nodes + board: push a node release, press *Update all*, both nodes report the
   new version; trigger an alarm mid-rollout and confirm it pauses; pull power from a node
   mid-download and confirm it recovers on the old firmware and retries.

### Phase 3 — Battery detector pull on wake  *(1–2 weeks)*

1. `fw_available` in the ESP-NOW check-in reply.
2. Detector: accept rules, temporary Wi-Fi STA join, HTTP pull, reboot, self-test, one ESP-NOW result, sleep.
3. Backoff / retry policy; awake-time measurement reported in the result.
   **Exit:** detector on battery updates itself within its next two wake cycles; measured awake
   time and mAh logged.

### Phase 4 — Release pipeline + cloud  *(1 week)*

1. CI builds, signs, size-checks, produces manifest, uploads to `internal` channel.
2. Lambda: list releases per channel; tablet downloads and caches them.
3. Channel promotion (`internal → beta → stable`) is a manual button in the admin tool.
4. Event log: `OTA_RESULT` persisted and synced.
   **Exit:** tag `v0.1.0` in git → 10 minutes later the tablet can download and apply it end to end.

### Phase 5 — Factory station + identity + sticker  *(2 weeks)*

1. Station script steps 1–8 from §5.2; jig for the detector PCB first.
2. Serial range allocation lambda; manufacturing DB table.
3. TEST mode in firmware (UART magic string within 3 s of boot).
4. Sticker QR format finalised and consumed by the provisioning flow in the app.
   **Exit:** 10 boards provisioned in a row with no keyboard input; all 10 appear in the cloud
   with test results; a sticker scanned by the app provisions the right device.

### Phase 6 — Production security + UL evidence  *(ongoing)*

1. Stage-2 (Secure Boot V2 + flash encryption + anti-rollback) enabled in the station for
   pilot units; verify OTA still works on them with a real signed release.
2. Written procedure: how a release is built, who approves promotion to `stable`, how the key
   is protected, how a site rollout is performed and recorded — this is the document the lab
   will ask for.
3. Version history + per-unit update log exportable from the cloud for any site.

---

## 8. Open points to confirm before Phase 2

- `[VERIFY]` `esp_image_verify()` behaviour on a non-app partition region (§3.2).
- `[VERIFY]` Mesh-Lite NAPT throughput at depth 2–3 and SoftAP max station count (affects detector join in §3.5).
- `[VERIFY]` `esp_https_ota` with plain HTTP + partial/resume support in the IDF version used.
- Decide the release cadence and who holds the "promote to stable" button.
- Decide whether the board gets an optional `factory` rescue app partition (space exists on 8 MB;
  not needed while USB reflash from the tablet is available).
- Decide where the board's **device table** lives above 120 units. Today it sits in the 24 KB `nvs`
  partition, capped at 120 (`installation-lifecycle-v1.md` §3.1) precisely so no partition changes
  ship before this table is frozen; reaching 250 needs either a bigger `nvs` or a dedicated data
  partition, fixed here once and never changed over the air.
