# Phase 3 brief — OTA: signed images, board self-update over USB, rollout through the mesh, leaf pull

_2026-09-28. The implementation plan behind `docs/ota/ota-and-production-blueprint-v1.md` (the design)
after the leaf link (`phase2-leaf-brief.md`) and the product catalogue (reference §2.1). Authority: below
the protocol, the blueprint and the OTA blueprint; this file records decisions, steps, the bench
checklist and what is deliberately not done. Written before any OTA code exists._

---

## 1. Why now

The network core is proven on the bench (mesh, failover, lifecycle, leaf link, parent role). Every
further bench cycle costs a cable per unit; OTA removes that cost and is the feature the certification
story needs (signed images, rollback, an update log). Nothing in the remaining leaf checklist blocks it.

## 2. Decisions (2026-09-28; the OTA blueprint holds the design, these settle what it left open)

1. **Three images, by family** — `board`, `node`, `leaf` (reference §2.1). A release is a manifest
   with one signed image per family; a unit accepts only its family's image (`project_name` check,
   OTA blueprint §4.3 item 2). The **model** (`SIOT-SIREN-01`, …) targets rollouts, never images.
2. **The model is a factory fact** (done 2026-09-28: `nvs_factory` key `model`, `tools/flash.sh --model`)
   — OTA blueprint Phase 0 item 6 is closed by that.
3. **Push over USB at 921600.** `OTA_PUSH_*` on the serial link switches the baud for the transfer and
   back; 4 KB chunks, each acknowledged, resume from the last acknowledged chunk (OTA blueprint §3.2).
4. **`fw_store` holds one file per family** (`/fw/node.bin`, `/fw/leaf.bin`, later per model if a family
   ever splits) plus `manifest.json` and `rollout.json`; the board's 8 MB table is the product table —
   the bench board is the 8 MB module, built with the default table (`build.sh board`, no `--flash 4mb`).
5. **Nodes pull over plain HTTP** from `http://192.168.4.1/fw/<family>.bin` with the IDF OTA client
   (`CONFIG_ESP_HTTPS_OTA_ALLOW_HTTP`, verified present in 5.5.2); depth ≥ 2 through Mesh-Lite NAPT.
6. **Order and control in SAFR**: `OTA_OFFER` per unit, one at a time, root last, `PAUSED` on any alarm,
   `UPDATING` instead of missing for `deadline_s`; `OTA_STATUS` (percent) and `OTA_RESULT` back (OTA
   blueprint §3.4). Targeting by model / zone / unit is the scheduler's queue filter.
7. **Leafs**: the offer rides the **leaf ACK's appended fields** (protocol §12.4 reserved this by length):
   `fw_version`, `fw_size`, `sha256` — never a mailbox frame. A leaf pulls on that wake if battery ≥ 60 %,
   joins the Wi-Fi as a station for the download only (OTA blueprint §3.5).
8. **Stage-1 signing from the first OTA image** (`SECURE_SIGNED_APPS_RSA_SCHEME`, `SECURE_SIGNED_ON_UPDATE`,
   OTA blueprint §1.3): a development key outside git, the public key compiled in. Secure boot and
   anti-rollback stay Phase 6 of the OTA blueprint.
9. **The tablet is the operator's window**: a new **Atualização** screen (§6) fed by one new uplink frame,
   `OTA_ROLLOUT`, the board's rollout table paged like `DEVICE_TABLE`, pushed on every change and every
   5 s while rolling. Results persist in the tablet's database (a new table — §3.6.1 updated in the same
   change).
10. **`force` (downgrade) exists for the bench only** and is refused in production builds.
11. **Protocol first**: every new message goes into `docs/safr/protocol-safr-v3.md` (revision 3.5) before
    code, with host tests for the codecs.
12. **Versioning rules** (2026-09-28). One version per **release**, from the git tag, through
    `firmware/VERSION` into every image's `esp_app_desc_t` (covered by the signature) and its boot line;
    a release = the board, node and leaf images built from one tag. A unit accepts an image only if
    `version > running` (semver); `force` is bench-only and compiled out of production builds. A
    `-dev` / dirty version is refused by the tablet for any rollout outside bench mode. Every unit reports
    its version (and model) in `NAME_ANNOUNCE` from step 0; the board's table, the Rede sheet and the
    rollout table show "runs X → target Y"; `OTA_RESULT` carries the version actually running. Results
    are journaled on the board and persisted on the tablet (per-unit update history). Anti-rollback in
    eFuse comes with secure boot (OTA blueprint Phase 6).
13. **A unit's product is fixed at the factory.** No field command changes a model (decided 2026-09-28
    after discussion): "update only sirens" is a rollout **filtered by model**, both products running the
    same node image at possibly different versions, which the additive protocol allows.

## 3. What exists already

- OTA blueprint: partition tables (§1.1/§1.2), build config (§1.3), hardware fit (§1.4), push / rollout /
  pull flows (§3), acceptance checks (§4.3), self-test (§4.4), factory station (§5), security stages (§6).
- In the builds: `CONFIG_BOOTLOADER_APP_ROLLBACK_ENABLE=y` on all three images; version from `firmware/VERSION`
  into `esp_app_desc_t`; `project_name` per image; `fw_store` in `partitions_board.csv`.
- Model in `nvs_factory`; pin map with families; images refuse a foreign family's model.
- Leaf ACK with length-versioned appended fields (protocol §12.4).

## 4. Protocol additions (revision 3.5 — write these first)

| Message | Link | Payload (draft) | Notes |
|---|---|---|---|
| `OTA_PUSH_BEGIN` 0x0F | serial ↓ | `family u8` (0 board · 1 node · 2 leaf) ‖ `size u32` ‖ `sha256[32]` ‖ `ver_len u8` ‖ `version` ‖ `chunk u16` (4096) | board opens the inactive slot (board) or `/fw/<family>.bin` (node / leaf); ACK carries `DETAIL` = accepted / busy / no space |
| `OTA_PUSH_CHUNK` 0x10 | serial ↓ | `seq u32` ‖ `data` (≤ 4096, but SAFR frames are ≤ 250 B: the chunk rides **raw after the frame**, length from BEGIN, CRC-32 appended) | the ACK's `ACKED_MSG_ID` = the chunk's; resume = the tablet re-sends from the last acknowledged `seq` |
| `OTA_PUSH_END` 0x11 | serial ↓ | — | board verifies signature + sha256 + `project_name`, answers `OTA_PUSH_RESULT` |
| `OTA_PUSH_RESULT` 0x12 | serial ↑ | `ok u8` ‖ `reason u8` ‖ `family u8` ‖ `version` | reasons: sig_fail, sha_fail, wrong_project, no_space, aborted |
| `OTA_BAUD` — CMD 0x1A | serial ↓ | `baud u32` | the board switches after ACKing; the tablet switches after the ACK; the link falls back to 115200 on 20 s of silence (spec §9.3) |
| `OTA_OFFER` — CMD 0x1B | mesh ↓ / leaf ACK fields | `family` ‖ `size` ‖ `sha256` ‖ `version` ‖ `deadline_s u16` ‖ `flags` (`force` bench only) | to one unit (`DST_MAC`); leafs: appended to the 9-byte leaf ACK |
| `OTA_STATUS` 0x13 | mesh ↑ | `state u8` (offered · downloading · verifying · rebooting · selftest) ‖ `percent u8` | every 10 % and on each state; no ACK |
| `OTA_RESULT` — EVENT? no: 0x14 | mesh ↑ | `ok` ‖ `reason` ‖ `version_now` | `F_ACK_REQ`; the board journals it |
| `OTA_ROLLOUT` 0x15 | serial ↑ | paged: `state` ‖ `release version` ‖ per unit `mac ‖ family ‖ model_len ‖ model ‖ version_now ‖ target ‖ state ‖ percent ‖ attempts ‖ reason ‖ last_change_age_s` | reply to `GET_ROLLOUT` (CMD 0x1C) and pushed on change / every 5 s while rolling |
| `OTA_CONTROL` — CMD 0x1D | serial ↓ | `action u8` (start · pause · resume · abort) ‖ filter (`model` / `zone` / `mac`, optional) | the tablet's buttons |

**Done 2026-09-29 (protocol §7.11 / §7.12, reference §2.1):** `NAME_ANNOUNCE` carries `PRODUCT u16 ‖
HW_REV u8 ‖ FW_LEN u8 ‖ FW`; the board keeps them per unit in its device table and gives them to the
tablet in `DEVICE_TABLE` (format 1); the tablet stores and shows them. **The product travels as a 16-bit
code (`family byte ‖ product byte`), not as the model string** — so wherever this brief says "model" on
the wire (`OTA_ROLLOUT`'s `model_len ‖ model`, the `OTA_CONTROL` filter) read `product u16`, and wherever
it says `family u8` (0 board · 1 node · 2 leaf) read the PRODUCT family byte (`0x01` · `0x02` · `0x03`).
**The rows above are the 2026-09-28 draft; the layouts that count are protocol §13** (written
2026-09-29), which differ where this note says and in three more places: the leaf image is addressed by
its family like the others; `OTA_PUSH_RESULT` carries `PHASE` and `NEXT_SEQ` (it is also the resume
answer); `OTA_RESULT` carries `AWAKE_S`. The board announces its own product and version with a
`NAME_ANNOUNCE` after each `DEVICE_TABLE` it sends to a v3.5 tablet.

## 5. Steps (each ends with something you can see)

**The goal of this phase is milestone M1 = steps 0–2: send a firmware from the tablet and have it
reach only the intended units.** Steps 3–6 polish, extend to leafs, automate the release and produce
the evidence; none of them is needed for M1.

| Step | What | You see | Status |
|---|---|---|---|
| **0. Spec + signing** | Protocol v3.5 (§4), host tests for every codec; dev signing key, stage-1 config on all three images, CI refuses an unsigned image; `NAME_ANNOUNCE` model + version; board table + tablet show model and version per unit | Rede sheet shows "SIOT-LEAF-01 · 0.1.0"; an unsigned `.bin` will not install | **Done in code 2026-09-29** — protocol §13 written; `siot_ota_proto` codecs + version rule, 8 host tests; stage-1 signing on the three images, key outside git (`docs/ota/signing-key.md`), `ci/check.sh` fails an unsigned image; product + version in `NAME_ANNOUNCE`, the board table and the tablet; the board announces itself. **Bench pending:** O1 needs step 1 (nothing installs over the air yet). Dart codecs for the push come with step 1 |
| **1. Push over USB, any image** | `ota_usb` on the board (BEGIN / CHUNK / END, 921600 switch, resume, `OTA_PUSH_RESULT`): the board's **own** image goes to the inactive slot → verify, reboot, self-test §4.4, mark valid / rollback; a **node or leaf** image lands in `fw_store` (FAT, wear-levelled, `/fw/<family>.bin` + manifest) and is verified there. Tablet: pick a `.bin` (file; a release in step 5), push with progress + resume | The board reboots into a pushed board image and the tablet shows it; a broken one rolls back with `selftest_fail`; a pushed node image reads "staged on the board", visible at `http://192.168.4.1/fw/manifest.json` | — |
| **2. Rollout to the intended units** | `ota_server` (HTTP on the installation AP, on only while a rollout runs); `ota_client` on the node (offer rules, pull via `esp_https_ota`, `project_name` + version check, reboot, self-test, result); `ota_scheduler` on the board (queue **filtered by model / zone / unit**, one at a time, root last, PAUSED on alarm, UPDATING, retries, `rollout.json` survives a reboot); `OTA_ROLLOUT` to the tablet and a **minimal rollout table + failure list** on the tablet (enough to run the bench checks; the full screen is step 3) | Two nodes update one after the other from one push, root last; a release for `SIOT-SIREN-01` leaves a `SIOT-PBS-01` untouched; the map shows UPDATING; an alarm pauses it; power cut mid-download → old firmware, retry | — |
| **3. Tablet Atualização screen** | §6 in full | Release card, push progress, rollout table by model, failure feed persisted, pause / resume / abort, numbers | — |
| **4. Leaf pull on wake** | Offer in the leaf ACK's appended fields; leaf: accept rules (version, battery ≥ 60 %, not in alarm), Wi-Fi STA join for the pull, `esp_https_ota`, reboot, self-test on the next wake, `OTA_RESULT`, backoff (next wake, then 6 h, max 5); awake time in the result | A leaf updates within two wakes; its awake time and the battery cost are on the tablet | — |
| **5. Release pipeline** | Tag → CI builds, signs, size-checks, writes the manifest, uploads; tablet lists and downloads releases; channel promotion | Tag `fw-0.2.0` → the tablet offers it | — |
| **6. Freeze + evidence** | Written release / rollout procedure (OTA blueprint §7 Phase 6 item 2); per-unit update log exportable | The document a lab asks for | — |

Steps 0–2 (M1) are one bench set: the 8 MB board, two node devkits stamped with two different models
(`tools/flash.sh node <port> --model SIOT-SIREN-01` / `--model SIOT-PBS-01`), the tablet. Step 4 adds the
leaf devkit.

## 6. The Atualização screen (tablet)

- **Release card**: version, build date, sha256 per family, signature status, "on the board: node 0.1.0 /
  leaf 0.1.0" versus the release.
- **Push to the board**: progress bar, chunks acknowledged / total, throughput, resumes counted, board
  self-update state (verifying · rebooting · self-test · ok · rolled back with reason).
- **Rollout**: filter (all · model · zone · unit), then a table, one row per unit, grouped by model:
  version now → target, state (waiting · offered · downloading N % · verifying · rebooting · self-test ·
  done · failed · skipped), attempts, last change. Leafs: "waits for its next wake" with battery, then the
  same states. Root marked "last". Header: ROLLING / PAUSED (alarm) / DONE / PARTIAL.
- **Failure feed**: every non-ok `OTA_RESULT` in plain words (downgrade refused, low battery, signature,
  self-test, HTTP error, timed out), persisted; reachable from the unit's Rede sheet too.
- **Controls**: Start (with the filter), Pause, Resume, Abort; disabled while an alarm is latched.
- **Numbers on screen**: minutes elapsed, units done / total, estimated remaining at the measured rate.

## 7. Bench checklist

- [ ] **O1** Unsigned image refused on every image (stage-1 signing).
- [ ] **O2** Push `board.bin` at 921600: throughput ≥ 60 KB/s, resumes after a pulled-and-replugged USB.
- [ ] **O3** Board reboots into the new version, self-test passes, tablet shows the version.
- [ ] **O4** Broken board image (self-test fails on purpose) → rollback, `selftest_fail` on the tablet.
- [ ] **O5** `node.bin` pushed into `fw_store`, verified; `http://192.168.4.1/fw/manifest.json` from a laptop on the installation Wi-Fi.
- [ ] **O6** Depth-2 node downloads through the root (NAPT); throughput noted.
- [ ] **O7** Rollout of two nodes: one at a time, root last, UPDATING on the map, both report the new version.
- [ ] **O8** Alarm mid-rollout → PAUSED; RESET → RESUME continues.
- [ ] **O9** Power cut mid-download → the node comes back on the old image, retries, succeeds.
- [ ] **O10** Filter by model: a release for `SIOT-SIREN-01` leaves a `SIOT-PBS-01` untouched.
- [ ] **O11** Downgrade refused; `force` accepted only on a bench build.
- [ ] **O12** Leaf: offer in the ACK, pull on that wake, self-test on the next, result on the tablet; awake time logged.
- [ ] **O13** Leaf with battery < 60 % refuses and says so.
- [ ] **O14** Atualização screen matches the logs end to end; failures readable the next day.
- [ ] **O15** Board reboot mid-rollout → `rollout.json` resumes the queue.

## 8. Numbers (targets; measured values replace them)

| Quantity | Target | Source |
|---|---|---|
| USB push at 921600 | ≈ 60–80 KB/s → node image ≈ 15 s | OTA blueprint §1.4 |
| Node download over the mesh | ≈ 40 s per node incl. reboot + self-test | OTA blueprint §1.4 |
| Site of 250 nodes | < 3 h, background, paused by alarms | OTA blueprint §3.4 |
| `deadline_s` (UPDATING instead of missing) | 300 s | OTA blueprint §3.4 |
| Self-test window | 120 s after the new image boots | OTA blueprint §4.4 |
| Leaf pull | battery ≥ 60 %, ≈ 40–90 s awake, once per release | OTA blueprint §3.5 |
| Image cap | node / leaf 1.75 MB (CI); board 2.375 MB slot | OTA blueprint §1.1 / §1.2 |

## 9. Deliberately not done in this phase

- Secure boot V2, flash encryption, anti-rollback eFuse (OTA blueprint Phase 6).
- Mesh-Lite's own hop-by-hop OTA (D3: HTTP pull is v1).
- Cloud-side rollout control (viewers see the rollout state only, Phase 5 of the OTA blueprint).
- Factory station (OTA blueprint Phase 5) — the model on the sticker is in place for it.

## 10. Open risks

1. The 921600 switch on the tablet's `usb_serial` plugin and the board's UART with no flow control; the
   fallback to 115200 on silence must be bullet-proof or the panel loses its board.
2. `esp_image_verify()` on a FAT-stored file (OTA blueprint §8): may need the inactive slot as scratch.
3. Mesh-Lite NAPT throughput at depth 2–3 while heartbeats and leaf traffic continue.
4. A leaf joining Wi-Fi as a station on a parent's SoftAP: station count limits and the parent's own
   Mesh-Lite role (OTA blueprint §3.5 item 4).
5. RAM on the N4 root during a download it relays plus its own custody / mailbox duties.
