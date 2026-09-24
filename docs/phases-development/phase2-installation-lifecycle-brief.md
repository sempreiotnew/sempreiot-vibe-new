# Phase 2 brief — Installation lifecycle (app + firmware)

_2026-09-24. The implementation plan behind `docs/others/installation-lifecycle-v1.md`, with the status
of every step and the checklist that says what is done, what still needs the bench, and what is
missing. Authority: below the lifecycle spec; this file records work, the spec records rules._

---

## 1. Why

The Instalação flow worked for one installer, one phone, one pass. Everything after that was missing
or unsafe: the phone was the only key holder, the backup QR carried both keys in clear, the board's
roster was written once and capped at 8, nothing on a provisioned unit could change over the air,
Case B was an undefined command, and the tablet's Instalação screen had no PIN. The user's
requirements: every install order must work, several installers in parallel, add / replace / retire /
rename later, recover from a lost phone, a dead board or a dead tablet, spec first, no Cognito or
backend changes, no partition-table changes before the OTA phase.

## 2. Decisions (see lifecycle §1–§4 for the rules)

1. Membership = holding the code; install order is irrelevant; phone lists are work logs, never merged.
2. The board's device table is the roster: discovered from traffic, annotated by the tablet.
3. The sticker `pop` is the universal proof of physical authority (provisioning, Case B, code hand-out).
4. The code leaves a device only inside a passphrase-encrypted envelope or the pop-derived envelope.
5. Protocol changes are additive (v3.2); `VER` unchanged; old tablets keep working.
6. No partition changes (cap 120 in `nvs`); no Cognito / Amplify / AppSync changes.

## 3. Phases

| Phase | Scope | Status |
|---|---|---|
| 0 | Spec: lifecycle doc, protocol v3.2, blueprint / reference / brief / app-doc amendments, guide | **Done** 2026-09-24 |
| 1 | App only: encrypted backup v2 + share / join, `NET_SSID` fix, zones saved, `/enroll` retry + warning, dedup message, `EditorGate` on Instalação, SYSTEM_ID banner, codec groundwork | **Done** 2026-09-24 (90 Flutter tests) |
| 2 | Firmware board + node + protocol + tablet UI: device table, lifecycle commands, setup channel (Case B + GET_CODE), node handlers, `409 already_stored`, survey mode, Drift v8, management UI | **Done in code** 2026-09-24 — **bench pass pending** |
| 3 | Board admin window (double tap) + phone "Entrar pela placa" | **Done in code** 2026-09-24 — **bench pass pending** |
| 4 | Optional: cloud escrow, re-key, wizard `/status = online` | **Not started — missing by design** (§7) |

## 4. What was built, by area

### Firmware (ESP-IDF 5.5.2; board, node, 4 MB board and host tests all build)

- `components/platform/siot_devtab/` — device table: NVS namespace `siot_devtab`, key = MAC hex, record
  role/state/flags/first_seen/name/zone, cap `CONFIG_SIOT_DEVTAB_CAP` = 120, derived online/missing
  (AC 45 s, leaf 450 s). Erased by `siot_config_factory_reset()`.
- `siot_coordinator.c` — rewritten on the table: retired MACs dropped after CCM; NAME_ANNOUNCE adopts
  name/zone/role; pending SET_DEVICE / DECOMMISSION pushed on the unit's next frame; commands
  0x12–0x18 with ACK `DETAIL`; INSTALLATION encoded from the table (legacy); `coord_devtable.c` pages
  DEVICE_TABLE to ≤ 202 bytes; TOPOLOGY from online entries.
- `coord_setup.c` — setup channel on USB (SYSTEM_ID 0x0000, key = HKDF(pop, salt = id,
  "siot-setinst-v1")): SET_INSTALLATION in SETUP (Case B, reboot), GET_CODE when provisioned → CODE.
- `coord_admin.c` — admin window: double tap → `siot_link_mesh_board_suspend()` to `SIOT-SETUP-<id>`,
  `siot_provisioning_admin_start()` (`/info`, `/identify`, `GET /code`, `/status`), 5 min, closes 2 s
  after delivery, refused within 10 min of an ALARM, white blink while open.
- `siot_safr` — MSG 0x0B–0x0E, CMD 0x11–0x19, ACK DETAIL codes; `siot_safr_build_frame_with()` /
  `siot_safr_parse_frame_with()` (explicit key, setup channel only).
- `siot_provisioning` — `409 already_stored`; enroll sink into the table (no cap of 8);
  `siot_prov_derive_setup_key()`; `siot_prov_encrypt_envelope()`; admin HTTP mode.
- `siot_netcore.c` (node) — SET_DEVICE (store + re-announce), DECOMMISSION (ACK, 300 ms, wipe, reboot;
  only when DST == own == ARGS, never broadcast), NAME_ANNOUNCE role byte, TEST = survey while level 0.
- `components/net/siot_survey/` — PARENT_PROBE / PARENT_OFFER over ESP-NOW on the AP interface; result
  event `SIOT_EVT_SURVEY_RESULT`; `siot_ui_led` yellow pattern + 3 s verdict.
- `test/host` — 33 tests incl. the setup-channel vector (byte-exact with the app fixture) and the
  envelope encrypt direction.

### Flutter app (analyze clean, 90 tests)

- Installer: `installation_backup_codec.dart` (PBKDF2 + AES-GCM v2), share dialog, rename / delete,
  work-log removal, `join_installation_screen.dart`, `join_from_board_screen.dart`, wizard header with
  the installation name, `/enroll` retry + warning, already-configured hint, `NET_SSID = SIOT-<hex4>`.
- Tablet: `EditorGate` on Instalação; v2 / legacy import; share; "Ler código da placa (USB)"; "Criar
  instalação nesta central" (Case B); "Reenviar nomes à placa"; `foreignSystemIdProvider` banner;
  Drift v8 (`boardState`, `boardFlags`, `tableSyncedAt`) + prune after a full table sync; node sheet
  "Gerenciar" (rename/zone, retire, reactivate, replace, wipe with typed name, forget) with audit rows;
  "Ressincronizar com a placa".
- Codec: `SafrCommand` 0x11–0x19, `SafrAckDetail`, `SafrInstallationCode`, `SafrDeviceTablePayload`,
  `SafrSetDeviceArgs`, probe/offer payloads; downlink lifecycle sends with DETAIL; setup channel
  (`setupChannelProvider`, `sendSetInstallation`, `sendGetCode`); `tool/print_setinst_vectors.dart` →
  `test/fixtures/setinst_vectors.json`.

## 5. Deploy for the bench pass

```
source ~/.espressif/tools/activate_idf_v5.5.2.sh
firmware/build.sh board --flash 4mb                    # apps/board/build-4mb
firmware/build.sh node                                 # apps/node/build
tools/flash.sh board /dev/cu.usbserial-XXXX --flash 4mb   # no --erase: keeps code + identity
tools/flash.sh node  /dev/cu.usbserial-YYYY
cd mobile/sempreiot_central_app
flutter build apk --dart-define=APP_MODE=central       # tablet (DB migrates v7 → v8)
flutter build apk --dart-define=APP_MODE=app           # installer phone
```

## 6. Checklist

Legend: `[x]` done and verified by build/tests · `[ ]` pending (bench) · `[-]` not done, missing.

### Phase 0 — spec
- [x] `docs/others/installation-lifecycle-v1.md` (rules, device table, custody, scenarios A–M, dedup, leafs, survey, gating, limits, phase map)
- [x] `docs/others/installation-guide.md` (step by step, per phase)
- [x] `docs/safr/protocol-safr-v3.md` v3.2 (setup channel, ACK DETAIL, CMD 0x11–0x19, MSG 0x0B–0x0E)
- [x] Blueprint rule 5, Case B, maintenance, LED language; reference rows 1.2–1.12, 7.1–7.2, §3.6.1, index; brief §14 items 1, 2, 11; OTA §8 open point; APP-BRIEF and app-doc notes

### Phase 1 — app
- [x] Encrypted backup v2, share (phone / tablet), join with passphrase, dedup by SYSTEM_ID
- [x] `NET_SSID = SIOT-<SYSTEM_ID hex4>`; zones saved from the wizard; `/enroll` retry + warning
- [x] Wizard shows the installation name; "já foi configurado" hint on timeout
- [x] Tablet Instalação behind `EditorGate`; legacy plaintext accepted with a warning; audit rows
- [x] SYSTEM_ID mismatch banner on the dashboard; local rename gated
- [x] v3.2 codec + vector fixture; tests: generator, codec, v32 roundtrip, central installation

### Phase 2 — firmware + tablet (code done; bench pending)
- [x] `siot_devtab` + coordinator rewrite + DEVICE_TABLE paging + lifecycle commands (builds)
- [x] Setup channel: SET_INSTALLATION (Case B) and GET_CODE (`coord_setup.c`) — host test byte-exact
- [x] Node SET_DEVICE / DECOMMISSION / role byte; `409 already_stored`; survey component; LED verdict
- [x] Tablet: Drift v8, table ingest + prune, downlink commands with DETAIL, management UI, Case B UI, "Ler código da placa", "Reenviar nomes", resync — tests: device_table_ingest
- [ ] **Bench 1** device table: nodes appear with "Na placa: online"; board log `device table: N`
- [ ] **Bench 2** "Ler código da placa": Desvincular → type the board pop → card fills; log `GET_CODE`
- [ ] **Bench 3** rename: node log `SET_DEVICE: now "…"`, name survives a node reboot
- [ ] **Bench 4** pending rename: rename while the node is off → applied on return
- [ ] **Bench 5** missing after 45 s
- [ ] **Bench 6** retire / reactivate; "aposentado, mas transmitindo" badge
- [ ] **Bench 7** remote wipe: node back to white blink; then Esquecer
- [ ] **Bench 8** replace old → new (name/zone move, old wiped if online)
- [ ] **Bench 9** Case B: factory-reset board → "Criar instalação nesta central" → board reboots on the new SSID → share to a phone
- [ ] **Bench 10** dedup: second `/provision` before reboot → `409 already_stored`
- [ ] **Bench 11** survey: two nodes, board off, TEST → blue blink on the neighbour, green/yellow/red on the prober **(riskiest: ESP-NOW on the AP interface while JOINING)**
- [ ] **Bench 12** old tablet build still reads INSTALLATION 0x09 from the new board (compat)

### Phase 3 — admin window (code done; bench pending)
- [x] `coord_admin.c`, `link_mesh_board` suspend/resume, `prov_http` admin mode, `siot_prov_encrypt_envelope` — host test reproduces the app vector
- [x] Phone `join_from_board_screen.dart` (scan or type the board sticker, join, identify, `/code`, open, import)
- [ ] **Bench 13** double tap → white blink → phone "Entrar pela placa" receives the code → window closes → root reconnects within ~1 min
- [ ] **Bench 14** admin window refused within 10 min of an ALARM

### Phase 4 — optional, NOT DONE (this is what is missing)
- [-] **Cloud escrow**: store the v2 encrypted envelope under the installer's account (Amplify/AppSync); restore on a new phone. Needs a backend change, which was explicitly excluded so far.
- [-] **Re-key**: `REKEY 0x1A {envelope, switch_at}` down the mesh under the old key, board last, `switch_at` ≥ longest leaf interval; tablet confirmation; offline units re-provisioned. Documented limit: cannot exclude a compromised unit that is still online.
- [-] **Wizard `/status = online`**: the phone confirming "online" instead of stopping at `stored`. Conflicts with Mesh-Lite's AP+STA on the node; the spec prefers confirmation on the tablet.
- [-] Leaf-specific paths that wait for Phase 2 leaves: parent mailbox + ACK `PENDING` for rename/decommission of a sleeping detector (lifecycle §5.2), `PARENT_PROBE purpose = 0`.

## 7. Open risks recorded during implementation

1. ESP-NOW survey depends on the node's SoftAP staying on the installation channel while JOINING; unverified on hardware.
2. The admin window swaps the board's only radio; the root loses the board for up to 5 min. Refused during a recent ALARM, closes on first delivery.
3. Device cap 120 until the OTA phase decides the production partition table (OTA blueprint §8).
4. The Mesh-Lite managed component prints `patch does not apply` on every node build; pre-existing, build is green.
5. `first_seen` in the device table is 0 until the board adopts TIME_SYNC (brief §14 item 12).
