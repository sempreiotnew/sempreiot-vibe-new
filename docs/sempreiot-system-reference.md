# SempreIoT — System Reference (central catalogue of what the product does)

_Started 2026-09-22. This is the one document that lists **every functionality of the system**, what it
does in plain words, whether it exists today, and where it is specified and implemented. It is the
entry point for a new engineer, the answer sheet for customer questions, and the place a new feature
is registered before it is built. It does not replace the detailed docs — it indexes them (§7)._

**Maintenance rule:** a functionality is not "done" until it has a row in §3 with status
`Implemented` and a pointer to the code. A new feature starts as a `Planned` row. Status values:
`Implemented` (in the product image / app build) · `POC` (proven on the bench in `pocs/`, not yet in
the product firmware) · `Planned <phase>` · `Open` (not designed yet).

---

## 1. What SempreIoT is

A wireless fire-detection and alarm system for buildings. Smoke/heat detectors, sirens and I/O
modules form a self-healing **Wi-Fi mesh** (ESP32-S3, ESP-Mesh-Lite); battery-powered detectors talk to
the mesh by **ESP-NOW**; a **board** at the top of the mesh is the control unit and bridges everything
over USB to a **tablet** that is the operator's panel. Everything on the wire is one binary,
authenticated protocol, **SAFR v3**. The system works with no internet; when internet exists, the
tablet mirrors status to the cloud so remote viewers can follow it. The design targets certification
under **UL 864 / NFPA 72 (US)** and **EN 54-25 / ISO 7240-25 (EU/international)**.

---

## 2. Parts of the system

| Part | What it is | Hardware / runtime | Status |
|---|---|---|---|
| **Board** | The control unit. Raises the installation's Wi-Fi access point, bridges the mesh to the tablet over USB, ACKs commands, journals every event, will latch alarms and supervise devices on its own. Never a mesh node. | ESP32-S3-WROOM-1-**N8R8** (8 MB flash + 8 MB PSRAM, PSRAM to be enabled — §4.1), mains + battery, native USB to the tablet | POC (`pocs/board`) → Phase 1 firmware |
| **Tablet (Central app)** | Operator panel: shows devices, events, alarms; SILENCE / RESET; latching and supervision today; talks to the board over USB only. | Android tablet, Flutter app in CENTRAL mode (`mobile/sempreiot_central_app`) | Implemented |
| **AC device** | Any mains-powered unit (siren, I/O module, AC detector, repeater). Mesh node; root-capable. | ESP32-S3-WROOM-1-**N4** (4 MB flash, no PSRAM; N8R8 is the fallback, same footprint — §4.1), one firmware image for every AC type | POC (`pocs/node`) → Phase 1 firmware |
| **Battery detector** | Battery-powered smoke/heat detector. Sleeps; wakes to talk to one AC device by ESP-NOW; never root, never relay. | ESP32-S3-WROOM-1-**N4** (§4.1), batteries, ADPD188BI smoke + HDC2080 temp/humidity | Planned Phase 2 |
| **Installer / Viewer app** | Same Flutter app on a phone. Installer functions (create installation, provision units) work offline; viewer functions need internet. | Android (iOS later), APP mode | Implemented (round 1) |
| **Cloud** | Mirrors the tablet's presence/status for remote viewers; access control between users and centrals. Never in the fire path. | AWS IoT Core (MQTT), Cognito, Lambda (`lambda/`) | Implemented (presence, storage, access) |
| **Factory station** | Writes identity into every unit and prints its sticker. | Python tool + flasher | Planned (OTA/production blueprint) |

---

### 2.1 Product catalogue (decided 2026-09-28)

**Two levels: TYPE and SUBTYPE.** The **type** is the *family* = the firmware image, by how a unit lives
on the network — `board`, `node` (every mains-powered unit), `leaf` (every battery unit). The **subtype**
is the *product* — **one model string per product**, written into the unit's factory
identity (`nvs_factory`, key `model`, next to `id` and `pop`; `tools/flash.sh --model`). At boot the
firmware reads the model and enables that product's peripherals and features; the pin map
(`tools/pinmap/pinmap.yaml`) has one entry per model with its family and its code, and every image refuses (logs an
error for) a model of another family.

**On the wire a product is a 16-bit code, never the string** (decided 2026-09-29): `family byte ‖ product
byte`, family `0x01` board · `0x02` node · `0x03` leaf. The string stays in the unit (17 bytes written once
cost nothing); the code is what travels and what the board keeps per unit (2 bytes against 17–32, in a
table sized for 250 units and paged in 202-byte frames), and a rollout filter on a number cannot miss a
unit over a typo. Every unit reports `PRODUCT`, `HW_REV` and the firmware version it runs in
`NAME_ANNOUNCE`; the board stores them in its device table and hands them to the tablet in `DEVICE_TABLE`
(protocol §7.11 / §7.12, v3.5). **A code is a contract: never reused, never renumbered** once a unit
shipped with it; a new product takes the next free code of its family. The trailing `-01` of a model is
the product generation, not the PCB revision (that is `hw_rev`). A product can be in the catalogue long
before its behaviour exists: the row, the code and the pin-map entry are enough for the unit to be
identified, listed and targeted by an update. OTA rolls out per image; the tablet can restrict a rollout by
model, zone or unit. A product is added with a catalogue row, a pin-map entry and a feature component
under `firmware/components/features/` — never with a new image, unless it no longer fits the family
(image cap 1.75 MB, or a different radio life).

| Code | Model | Product | Family / image | Power · network | PCB map | Status |
|---|---|---|---|---|---|---|
| `0x0100` | `SIOT-BOARD-01` | Board (control unit) | board | mains + battery · installation AP, USB to the tablet | `docs/spec/definition-central.md` | bench (devkit); product PCB pending |
| `0x0201` | `SIOT-SIREN-01` | Siren (`docs/devices/siren.md`) | node | mains · Mesh-Lite node, root-capable, leaf parent | pending (devkit pins as placeholder) | planned: `features/siot_siren` (sounder, `COMMAND SOUND`) |
| `0x0202` | `SIOT-PBS-01` | Push-button (manual call) station (`docs/devices/push-button-station.md`) | node | mains · Mesh-Lite node, root-capable, leaf parent | pending | planned: station input → `EVENT ALARM` (manual) |
| `0x0203` | `SIOT-IO-01` | I/O module | node | mains · Mesh-Lite node, root-capable, leaf parent | pending (devkit pins as placeholder) | **identity only** (2026-09-29): behaviour undefined |
| `0x0204` | `SIOT-REPEATER-01` | Repeater | node | mains · Mesh-Lite node, root-capable, leaf parent | pending (devkit pins as placeholder) | **identity only**: the plain node image is already its behaviour |
| `0x0205` | `SIOT-SMOKE-AC-01` | AC smoke detector | node | mains · Mesh-Lite node, root-capable, leaf parent | pending (devkit pins as placeholder) | **identity only**: behaviour undefined |
| `0x0301` | `SIOT-SMOKE-01` | Battery smoke detector (`docs/devices/smoke-detector.md`) | leaf | batteries · ESP-NOW to a parent node, sleeps | `docs/spec/definition-detector.md` | leaf link coded; sensing phase pending |
| `0x0302` | `SIOT-HEAT-01` | Battery heat detector | leaf | batteries · ESP-NOW to a parent node, sleeps | pending (devkit pins as placeholder) | **identity only**: behaviour undefined |
| `0x02FF` | `SIOT-NODE-01` | generic bench AC unit (devkit) | node | — | devkit | bench only |
| `0x03FF` | `SIOT-LEAF-01` | generic bench battery unit (devkit) | leaf | — | devkit | bench only |

A
hardware revision field is kept beside the model (`hw_rev`, 0 = any) for the day a `-02` PCB needs a
different pin map under the same product. Units stickered before this key existed keep the image's
build default (`CONFIG_SIOT_DEV_MODEL`); re-stamping a sticker keeps its id and pop.

## 3. Functionality catalogue

### 3.1 Identity, installation and provisioning

| # | Functionality | What it does | Status | Spec | Code |
|---|---|---|---|---|---|
| 1.1 | Factory identity + sticker | Every unit ships with `id` + `pop` (secret) in a read-only NVS partition and a QR sticker `{id, mac, pop}`. No identity is ever typed by hand. | POC (`make_sticker.py`, `siot_fact`) → Phase 1 moves it to `nvs_factory` | blueprint §2, OTA blueprint §1/§4 | `tools/make_sticker.py`, `siot_prov/prov_store.c` |
| 1.2 | Installation code | One bundle per site: `SYSTEM_ID`, `NET_SSID = SIOT-<SYSTEM_ID hex4>`, `NET_PSK`, `SAFR_PSK`, `CHANNEL`, `MESH_ID`. Created once by whichever app comes first; every unit, board included, holds the same code. | Implemented (app) / POC (firmware) | blueprint §0, POC-BRIEF §6.1 | `features/installation/` (app), `prov_types.h` |
| 1.3 | Setup network | An unprovisioned unit raises `SIOT-SETUP-<id>` (WPA2 = `pop`) with an HTTP server. | POC | POC-BRIEF §4.1/§5 | `siot_prov/wifi_softap.c`, `prov_http.c` |
| 1.4 | Provisioning handshake | Phone joins the setup network, proves it read the sticker (`HMAC(pop, nonce)`), pushes the code encrypted (AES-CCM under a key derived from `pop`), sets name + zone. ~20 s per unit, offline. `GET /info` says what the unit is — `model`, `fw`, and (2026-09-29) `product` (the PRODUCT code of §2.1), `family`, `hw_rev` — and the wizard shows "Produto" and "Firmware" before the installer confirms and keeps them in the phone's work log. **Confirmation (fixed 2026-09-29):** `/provision` answers `202` only after the code is in flash; the first `GET /status` then answers `stored` and the unit reboots **1 s after that reply** (30 s cap if nobody polls). The first firmware rebooted inside the `/status` handler, before replying, so the wizard never read `stored` and sat on "Enviando informações" until its 60 s timeout; the wizard now also takes the `202` as the unit's own confirmation, so a setup network that disappears after it ends on "Configuração salva", with old firmware too. | Implemented (app wizard) / POC (firmware) | POC-BRIEF §5, blueprint §3 | `features/provisioning/` (app), `prov_http.c`, `prov_crypto.c` |
| 1.5 | Board device table | The board keeps one entry per MAC (`expected/online/missing/retired`, name, zone, role), discovered from authenticated traffic and edited by the tablet; `/enroll` is only an "expected" hint; retired MACs are dropped after CCM; pending rename/decommission pushed on the unit's next frame; cap 120 in the existing `nvs`. Replaces the ≤ 8 enrolled list. | Implemented (firmware + tablet, lifecycle Phase 2, 2026-09-24; bench test pending) | `installation-lifecycle-v1.md` §3, spec §7.12 | `siot_devtab`, `siot_coordinator.c`, `coord_devtable.c`, app `_handleDeviceTable` |
| 1.5b | Sharing the code / backups | The code leaves a phone or tablet only as a passphrase-encrypted QR (v2, PBKDF2 + AES-GCM); second installers use "Entrar em instalação existente"; plaintext v1 backup is read-only legacy with a warning on the tablet. Instalação screen and tablet rename behind `EditorGate`; wizard shows the installation name and the "já foi configurado" hint; SYSTEM_ID mismatch banner on the dashboard. | Implemented (app, lifecycle Phase 1, 2026-09-24) | lifecycle §2, §5 D, §5.1, §7 | `installation_backup_codec.dart`, `join_installation_screen.dart`, `central_installation_screen.dart`, `foreignSystemIdProvider` |
| 1.6 | Tablet reads the installation from the board | On USB link-up the tablet asks `GET_INSTALLATION`/`GET_DEVICE_TABLE`; the board answers identity, SSID, channel, name and the device table — never the secrets. **The code itself** the tablet pulls once with `GET_CODE` on the setup channel after the operator types (or scans) the board sticker's `pop` — no camera, no phone needed (lifecycle §4.1). | Implemented (firmware `coord_setup.c` + tablet "Ler código da placa", lifecycle Phase 2, 2026-09-24; bench test pending) | spec §3.1/§7.6/§7.10/§7.12/§7.13 | `coord_setup.c`, app `safr_downlink_provider.dart` `sendGetCode` |
| 1.7 | Case A / Case B installation | A: installer provisions units before the board exists; B: tablet + board first (tablet arms the board with `SET_INSTALLATION` on the pop-keyed setup channel, "Criar instalação nesta central"), phone scans the encrypted installation QR from the tablet. Any order, any number of installers. | A: POC · B: Implemented (Phase 2, 2026-09-24; bench test pending) | blueprint §3, lifecycle §5 | `coord_setup.c`, app `central_installation_screen.dart` |
| 1.8 | Factory reset | Button held 5 s at any time wipes the code (keeps identity) and returns to setup mode. | POC | blueprint §2 | `node_button.c`, `board_button.c` |
| 1.9 | Device naming | Each unit announces its operator-given name, zone and role after boot (`NAME_ANNOUNCE`); the tablet shows names, never MACs. Renames from the tablet go to the board and the unit (`SET_DEVICE`; the unit stores and re-announces). | Implemented (Phase 2, 2026-09-24; bench test pending) | spec §7.11, §7.6 0x12 | `siot_netcore.c` `apply_set_device`, app node sheet |
| 1.10 | Survey mode | TEST button on a provisioned unit with no path to the board: ESP-NOW probe (×4) / offer range test between units and the board, via Mesh-Lite's ESP-NOW layer on nodes. Passive units show 1 s green/yellow/red = how well they heard the probe (≥ −75 / ≥ −85 dBm); the pressed unit blinks once per answering unit in that link's colour, one red blink = nobody. **Leafs** (spec §12.8): survey runs *from* the leaf only; a press always transmits (immediate blue blink, then walk test if bound with a path, else survey); no dark period; a press on an unbound or `NO_PATH` leaf runs one discovery first (no LED); its survey blinks are a node's (400 ms on, 200 ms dark, through `siot_ui_led`); verdict after provisioning = what a press does, run by the leaf itself. | Implemented and **bench-verified 2026-09-24** (two nodes side by side: −14 dBm, green); per-unit colours added after the three-node run | lifecycle §6, spec §7.14/§7.15 | `siot_survey.c`, `siot_ui_led.c` |
| 1.12 | Board admin window | Double tap on the board: the installation AP is suspended and `SIOT-SETUP-<id>` (WPA2 = pop) comes up for 5 min with `GET /info`, `/identify`, `GET /code` (the code encrypted for the sticker, same envelope as `/provision` in reverse); closes 2 s after a delivery; refused within 10 min of an ALARM; LED white blink while open. Phone: "Entrar pela placa". | Implemented (lifecycle Phase 3, 2026-09-24; bench test pending — the root loses the board for the window) | lifecycle §11, spec provisioning HTTP | `coord_admin.c`, `prov_http.c` admin mode, `link_mesh_board.c` suspend/resume, app `join_from_board_screen.dart` |
| 1.11 | Provisioning dedup | `/provision` answers `409 already_stored` after the first success; the wizard explains the already-configured case. | Implemented (Phase 1 + 2) | lifecycle §5.1 | `prov_http.c`, wizard provider |

### 3.2 Network

| # | Functionality | What it does | Status | Spec | Code |
|---|---|---|---|---|---|
| 2.1 | Installation access point | The board raises `NET_SSID` on a fixed channel (1/6/11); nothing else creates Wi-Fi. | POC | blueprint §1/§4 | `board_main.c` |
| 2.2 | Self-forming mesh | AC devices run ESP-Mesh-Lite against the board's AP; the best link becomes root (level 1), the rest join under it, up to 4 levels. No user action. | POC | blueprint §4, brief §6.3 | `node_mesh.c` |
| 2.3 | Root failover | If the root dies, another AC device becomes root automatically; the mesh also survives the board being off and re-homes when it returns. Target < 60 s (max 120 s). | POC (numbers not yet recorded) | blueprint §7, POC-BRIEF §7 | `node_mesh.c` (`join_mesh_ignore_router_status`, keepalive, connect timeout) |
| 2.4 | Uplink path | Any node → root (Mesh-Lite raw message) → board (TCP) → tablet (USB). Frames are forwarded unchanged. | POC | brief §6.3 | `node_mesh.c`, `tcp_link.c`, `serial_link.c` |
| 2.5 | Downlink path | Tablet → board → root → broadcast down the tree with per-node re-broadcast and dedupe; each node acts only on frames addressed to it or broadcast. | POC | brief §6.3 | `node_mesh.c`, `root_duties.c` |
| 2.6 | Tablet link | Raw SAFR bytes at 115200 8N1 over USB (native USB-Serial-JTAG in the product; UART0 on the bench). Resync on frame boundaries after noise or boot chatter. | POC | spec §2, brief §6.5 | `serial_link.c`, app `serial_provider.dart` |
| 2.7 | ESP-NOW battery link | Battery detector wakes every 60 s (fixed), drains its outbox, sends HEARTBEAT (unicast, ACK required) to its bound AC device, gets the 9-byte leaf ACK (`PENDING` + count, `NO_PATH`, `EPOCH`, `CHANNEL`), drains the parent's mailbox if pending, sleeps; budget 500 ms. Binds by probe/offer (best link ≥ −85 dBm, shallow parent breaks ties); re-probes on the 2nd miss, after `NO_PATH`, daily; back-off every wake / 5 min while unbound. Parent takes custody of events; alarms are end-to-end with a broadcast fallback; no LED in sleep; 2-minute setup window then button-only sleep. | **Specified (spec v3.4 §12, 2026-09-28)** · leaf side and the node's parent role coded 2026-09-28 (bench pending) | spec §12, blueprint §5.1/§5.2/§6 | `siot_leafcore`, `siot_leaf_proto`, `apps/leaf`; node: `features/siot_leafmgr` (`phase2-leaf-brief.md`) |
| 2.8 | Site separation | Units of one installation cannot join or be understood by a neighbouring one: distinct Wi-Fi PSK, distinct `SYSTEM_ID` (dropped before decryption), distinct SAFR key. | POC | spec §3.1, blueprint §7 | `safr_frame.c` |

### 3.3 Protocol, security and delivery assurance (SAFR v3)

| # | Functionality | What it does | Status | Spec | Code |
|---|---|---|---|---|---|
| 3.1 | Authenticated, encrypted frames | Every frame on every hop: AES-128-CCM with a 16-byte tag, header authenticated, 12-byte nonce from sender MAC + boot counter + message counter, CRC-16 for wire integrity, `LEN ≤ 250`. | Implemented (app) / POC (firmware) | spec §3–§5 | `pocs/components/safr`, app `safr_crypto.dart` |
| 3.2 | Replay protection | Receivers remember the last counter pair per sender and drop older frames. | Implemented (app) · Planned Phase 1 (board/nodes) | spec §4 | app `safr_ingest_provider.dart` |
| 3.3 | Acknowledged delivery | Alarm and trouble events demand an ACK; unacknowledged frames are resent 3× (2 s apart) and then the sender raises its own communication trouble — it never gives up silently. **Leafs (spec §12.6):** every leaf event is ACKed by its parent on the same wake (custody: the parent retries upward until the board ACKs); an ALARM additionally waits for the board's end-to-end ACK, awake and sounding, and falls back to an ESP-NOW broadcast when the unicast fails; events with no parent at all wait in the leaf outbox (16, NVS-mirrored) and are delivered with their original timestamps. | POC (nodes) · Specified (leafs) | spec §7.2/§9.1/§12.6 | `node_safr.c` |
| 3.4 | Alarm re-announcement | An active alarm is repeated at least every 60 s until the operator resets, so it cannot be missed after a link outage. | POC | spec §7.2 | `node_safr.c` |
| 3.5 | Event identity and dedupe | Each event carries a device sequence number; repeats and replays never create duplicate alarms. | Implemented (app) / POC | spec §6 | app, `node_mesh.c` |
| 3.6 | Event journal and backfill | The board stores every event; after a USB outage the tablet requests what it missed (`EVENT_LOG_REQ`) and receives it deduped. ≥ 64 entries; flash-persisted in the product. | POC (RAM journal) → Phase 1 (flash) | spec §8 | `root_duties.c`, app |
| 3.7 | Severity priority | Alarm > supervisory > trouble > restore in every transmit queue and on screen. | Implemented (app) · Planned Phase 1 (firmware queue) | spec §0 | app |
| 3.8 | Time synchronisation | Tablet sends the clock to the board on link-up and hourly; the board pushes it into the mesh so event timestamps are real wall-clock. Leafs never receive `TIME_SYNC`: the parent's heartbeat ACK carries `EPOCH` (and `CHANNEL`) every wake (spec §12.4). | POC (nodes) · Planned Phase 1 (board clock) · Specified (leafs) | spec §7.7, §12.4 | `node_safr.c`, `root_duties.c` |

### 3.4 Supervision (knowing a device is alive)

| # | Functionality | What it does | Status | Spec | Code |
|---|---|---|---|---|---|
| 4.1 | Heartbeats and topology | Every powered device reports liveness every 15 s and its position in the mesh (parent, children, signal) every 60 s. A leaf reports liveness every 60 s on wake and sends one TOPOLOGY per bind listing its **parent candidates** with signal, which is what the walk-test report uses to flag "fewer than 2 parents" or a weak link (spec §12.7). | POC · Specified (leafs) | spec §7.3/§7.4/§9.2/§12.7 | `node_safr.c`, `root_duties.c` |
| 4.2 | Device-missing trouble | A device silent for 3 × its interval (45 s powered, 180 s battery) is flagged missing with a trouble; any valid frame restores it. Inside the 200 s (NFPA 72) / 300 s (EN 54-25) limits. **Root fast path (2026-09-27):** the board drops a dead root's TCP session in ~5 s, marks it missing and pushes DEVICE_TABLE; the tablet takes that as authoritative, so a dead root leaves the map in seconds, not 45. Nodes re-announce their role only once the new path is proven, and the board heartbeats the tree the moment a root connects, so the new tree is on the tablet ~2 s after the new root connects. | Implemented (tablet + board fast path) | spec §9.2, §7.12 | app `supervisionProvider`, `siot_coordinator.c` `on_link`, `siot_netcore.c` announce-pending |
| 4.3 | Downlink supervision | The tablet proves the link *towards* the board works: `LINK_CHECK` every 30 s, trouble after 3 unconfirmed. | Implemented (app) / POC (board ACKs) | spec §9.3 | app, `root_duties.c` |
| 4.4 | Link-quality trouble | Sustained CRC/auth failures (≥ 5 in 60 s) raise a trouble even if some frames get through. | Implemented (app) | spec §9.4 | app |
| 4.5 | Board self-reporting | The board reports itself as the layer-0 device so the tablet shows "mesh connected". Since 2026-09-27 its HEARTBEAT is also broadcast down the mesh every 15 s: the signal a joined node uses to know the board is there (LED online within 15 s of joining, tablet or not; before, it waited for the tablet's LINK_CHECK or a TEST tap). | Implemented (board + node) | spec §7.3, §9.3 | `siot_coordinator.c` `tx_sink`, `siot_netcore.c` `on_board_heartbeat` |

### 3.5 Alarm handling and operator actions

| # | Functionality | What it does | Status | Spec | Code |
|---|---|---|---|---|---|
| 5.1 | Alarm latching | An alarm stays on the panel until an operator RESET — never cleared by a restore, a timeout or silence. The tablet shows the held alarms in a red banner on Principal (broadcast REARMAR) and on the unit's sheet in Rede (per-device REARMAR); the latch clears only after the root ACKs the RESET. | Implemented (tablet) · Planned (board as control unit) | spec §7.1.4 | app `latched_alarm_banner.dart`, `alarm_latch_provider.dart` |
| 5.2 | SILENCE / RESET | SILENCE stops sounders and keeps the latch; RESET clears the latch only after the root ACKs and stops re-announcement at the device. | Implemented (app) / POC (device side) | spec §7.6 | app, `node_safr.c` |
| 5.3 | Test button | Short press on a **node** sends a `MANUAL_TEST` supervisory event with ACK required, distinct from a real alarm (walk test); the tablet ticks the unit with time and RSSI. Double tap = bench ALARM. Short press on the **board** broadcasts a `COMMAND TEST` into the mesh so **every node** raises its own `MANUAL_TEST` — a one-button site-wide walk test; the board raises no event of its own (decided 2026-09-23). Short press on a **leaf** wakes it and always transmits: walk test when bound with a path (blue → cyan when the panel's ACK comes back through the parent), survey otherwise (spec §12.8). Hold ≥ 5 s on any = factory reset (row 1.8). | Phase 1 firmware (steps 2–3) · Specified (leafs) | spec §7.1.2/§7.6/§12.8, blueprint §6.4 | `siot_ui_button`, `siot_netcore` (node), `siot_coordinator` (board) |
| 5.4 | IDENTIFY ("blink it") | From the tablet, make one unit blink blue for N seconds to locate it during commissioning. | POC | spec §7.6 | `node_safr.c` |
| 5.5 | Smoke / heat detection | ADPD188BI smoke and HDC2080 temperature with pre-alarm trend; raw values reported so thresholds can be verified by a lab. | Planned (sensing phase) | spec §7.1, GPIO docs | — |
| 5.6 | Sirens and cause-and-effect | Board sends `SOUND` to selected sirens; every siren also sounds on any authenticated alarm it overhears, board reachable or not. | Planned (`COMMAND SOUND` undefined) | blueprint §6 | — |
| 5.7 | Relay output | Remote control of the unit's relay (GPIO 12). | Planned | spec §7.6 (`RELAY_SET`) | — |
| 5.8 | Power and tamper troubles | AC lost, on battery, charging, tamper (removed from base), battery low/critical with ≥ 7 days (NFPA) / ~30 days (EN) warning. | Planned (inputs exist on the PCB; reporting is Phase 2+) | spec §7.1.2/§7.1.3 | `pocs/patinha` (GPIO reference) |
| 5.9 | Walk-test report | Tablet exports the installation report (units, zones, MACs, firmware, test times, RSSI) as PDF. | Planned | blueprint §6.4 | — |

### 3.6 Operator interface (tablet) and remote access

| # | Functionality | What it does | Status | Spec | Code |
|---|---|---|---|---|---|
| 6.1 | Central dashboard | Principal / Central / Dispositivos / Rede tabs, device registry with names, alarm-hold banner, comm-status tiles (Wi-Fi, USB, mesh, cloud). The Rede map keeps every registered unit: silent for > 10 min = drawn dimmed, never auto-removed; only the operator's "Limpar dispositivos" clears the registry. (The Eventos feed tab was removed 2026-09-23.) | Implemented | app doc §8 | `mobile/…/features/central` |
| 6.8 | Leaf states on the tablet | A battery detector is **Dormindo** (grey, moon icon with a small drifting "z z" inside the avatar circle; its link keeps the last dBm in the sleep colour, §3.6.2; every frame it sends travels the tree to the central as a packet in the LED language — blue sent, cyan for the ACK coming back, red alarm, orange trouble) whenever it is healthy and between wakes, **Acordado** for the seconds after a frame or while its alarm is latched, and **Sem comunicação** (red, synthetic "dispositivo ausente" trouble) after 180 s of silence or when the board's table says missing — never OFFLINE just for sleeping. The sheet shows the bound parent, last / next wake on the 60 s cadence, battery, pending commands ("aplica quando o detector acordar"), and **parents in reach** from the bind-time TOPOLOGY with a warning when fewer than 2 or the link is below −85 dBm. | Implemented 2026-09-28 (Acordado < 3 s or alarm latched · Dormindo with last / next wake on the 60 s cadence · Sem comunicação "há X" · parents in reach + single-parent / weak-link warnings, Drift v9) | `docs/devices/leaf.md` §8b, spec §12.7, app doc §5 | `topology_provider.dart`, `topology_screen.dart`, `supervision_provider.dart` |
| 6.2 | Unlock PIN | 6-digit PIN gates the operator UI; comms keep running underneath. | Implemented | app doc §1 | `main_screen.dart` |
| 6.3 | Event history | Append-only local event log (Drift DB, `DeviceEvents` — §3.6.1) — the panel event history NFPA 72 requires. Visible today through Logs seriais. | Implemented | app doc §2, spec §11 | `core/database` |
| 6.4 | Serial diagnostics | Raw packet log with CRC/auth/foreign/replay/plaintext diagnostics for the bench and for support. | Implemented | app doc §5 | `serial_logs` |
| 6.5 | Cloud presence and storage | The central publishes online/offline, link health and storage snapshot (retained MQTT); viewers see it live. | Implemented | app doc §6 | `iot/` |
| 6.6 | Viewer access control | A phone user requests access to a central; the operator accepts/rejects/blocks; levels enforced by IoT policies. | Implemented | app doc §4 | `access/`, `lambda/` |
| 6.7 | Remote events and alarms | Viewers receive real alarms/events/topology from the central. | Open — today only presence/storage/access reach the cloud | app doc §6 | — |

#### 3.6.1 Tablet local database (Drift, SQLite file `sempreiot`, schema v10)

The tablet keeps all of its state in one Drift database, `mobile/sempreiot_central_app/lib/core/database/app_database.dart`.
**This table is the catalogue of record: whenever a table is created, removed or renamed, update it in
the same change** (rule in `CLAUDE.md`).

| Table | Key | What it holds | Written by | Read by | Retention |
|---|---|---|---|---|---|
| `SerialPackets` | `id` (auto) | Every reframed USB frame: `receivedAt`, `deviceId` (serial port), `rawBytes`, `byteLength`, `hexPreview`. Forensics and the Logs seriais screen. | `serial_provider` / ingest | Logs seriais, SAFR detail | purged after 30 days |
| `DeviceMetadata` | `key` | Key/value JSON store for this central: `info` (name, firmware, subId, dates), `credentials` (PIN hashes, root, level PINs), `access` (viewer relations), `iot` (IoT client id/password), `pin_guard` (unlock rate limiter), `safr_jrn_seq` (journal high-water mark). | installation, credentials, access, IoT services, ingest | same | permanent (factory reset wipes) |
| `AuditEvents` | `id` (auto) | Append-only security trail: `at`, `actor` (`master`/`admin`/`root`/`system`/`central`), `action`, JSON `detail` (never a PIN or password). | PIN change, grants/blocks, unlock failures | Audit log screen (`recentAudit`) | permanent |
| `MeshDevices` | `mac` | Trusted device registry built only from authenticated SAFR frames: `role`, `layer`, `parentMac`, `lastRssi`, `batteryPct`, `firstSeenAt`, `lastSeenAt`, `lastHeartbeatAt`, replay counters `lastBootCtr`/`lastMsgCtr`, `supervisionState` (0 online / 1 missing), `name`, `zone`, `registryState` (`enrolled` = known from INSTALLATION / DEVICE_TABLE only), `lastDevSeq`, **`alarmLatched` + `alarmLatchedAt`** (the alarm hold, row 5.1), the **unit identity** (schema v10, protocol §7.11 / §7.12, catalogue §2.1): `productCode` (16-bit PRODUCT, high byte = family; null = never reported), `hwRev` (null = not stated), `fwVersion` (the firmware the unit runs) — written by the ingest from `NAME_ANNOUNCE` and from a `DEVICE_TABLE` entry, never replaced by an unknown / empty value, read by `topologyProvider` for the "Produto" / "Firmware" facts, and the v3.2 board-table mirror (schema v8, lifecycle §3): `boardState` (0 expected · 1 online · 2 missing · 3 retired, null = not in the board's table), `boardFlags` (spec §7.12 bits: seen-ever, annotated, pending rename, heard-while-retired, pending decommission), `tableSyncedAt`, and (schema v9, 2026-09-28, spec §12.7) **`parentCandidates`**: a battery leaf's parents in reach from its bind-time TOPOLOGY as JSON `[{mac, rssi}]`, null for nodes — feeds "Pais ao alcance" and the walk-test flags. A known leaf keeps `role` 2 across heartbeats. Rows the board no longer lists and that were only board-sourced are pruned after each full DEVICE_TABLE sync. | ingest (frames + DEVICE_TABLE), supervision, downlink (`clearAlarmLatch`), device management (rename/forget) | Rede map + node sheet, alarm banner, supervision, dedupe | until "Ressincronizar com a placa" / forget |
| `DeviceEvents` | `id` (auto) | Decoded event feed: `receivedAt`, `deviceMac`, `msgType` (0 = synthetic), wire `eventType`/`eventCode`, `severity` 0 ok · 1 trouble · 2 alert · 3 alarm, `detailJson`, `packetId` → `SerialPackets`, `errorKind` (crc_failed / auth_failed / foreign_system / plaintext_rejected / parse_error), `ackedAt`, `devSeq` (dedupe key with `deviceMac`). | ingest, supervision troubles, downlink link-check troubles | Logs seriais (joined to packets) | purged after 30 days |

#### 3.6.2 Signal colour scale (LEDs and the Rede map) — decided 2026-09-28

One scale for the whole product. The thresholds come from the survey (lifecycle §6, spec §7.15) and
the leaf's bind preference (spec §12.3); the app keeps them in `lib/core/theme/signal_colors.dart`.

| Link RSSI (the weaker direction) | Tier | Colour | Where it shows |
|---|---|---|---|
| ≥ −75 dBm | good | **green** | survey LED on the answering unit and the prober's per-unit blink; Rede: the link line, its dBm label, "Sinal" on the sheet |
| ≥ −85 dBm | weak | **yellow** | same; a leaf still binds to it (spec §12.3) and the sheet warns below −85 only |
| < −85 dBm | poor | **red** | same; walk-test flag "sinal fraco" (spec §12.7) |
| unknown | — | blue (the app's accent) | a link with no reading yet |

A **sleeping leaf's** link (row 6.8) keeps its last dBm on the line but is drawn in the neutral sleep
colour (grey), not the tier colour: the reading is from the last wake, still true but not live, and the
next frame may arrive through any parent. It gets its tier colour back the moment the leaf is awake.
Nodes in root election keep their amber dashed line; a link whose end is offline stays red dashed.

**Packets on the Rede map = the LED language (row 7.7).** A frame in flight is drawn as a small packet
(rounded body, header band, two data stripes) oriented along the link, in the colour the unit's own
LED shows for it: **blue** = a frame sent (heartbeat, walk test, name, a command going down) · **cyan**
= the tablet's ACK travelling back to the unit · **red** = ALARM · **orange** = TROUBLE. Never amber:
an ALERT such as the walk test is "blue up, cyan down", on the unit and on the tablet alike. AC nodes
animate events and the ACKs they wait for; a battery leaf animates every uplink frame (row 6.8). One wake = one
packet: frames a unit sends within 1.2 s merge into the packet in flight; the packet follows the parent the
frame itself names, so a leaf that re-bound is drawn on its new line from the first frame; the cyan ACK
packet exists only for an EVENT's acknowledgement, never for a heartbeat's.

### 3.7 Maintenance, updates, production

| # | Functionality | What it does | Status | Spec | Code |
|---|---|---|---|---|---|
| 7.1 | Add / replace / retire / rename / forget a unit | Same provisioning flow to add; tablet node sheet ("Gerenciar", Master/Nível 4 PIN) sends `SET_DEVICE`, `RETIRE`/`UNRETIRE`, `REPLACE_DEVICE`, `DECOMMISSION` (typed confirmation), `FORGET_DEVICE`; every action audited. | Implemented (Phase 2, 2026-09-24; bench test pending) | spec §7.6 v3.2, lifecycle §5 E–H | `siot_coordinator.c` `handle_lifecycle_command`, app `topology_screen.dart` |
| 7.2 | Replace the board / tablet / lost phone | Board: provision from any code holder or arm from the tablet (Case B), then "Reenviar nomes à placa"; tablet: "Ler código da placa" (`GET_CODE`) or the encrypted QR; phone: encrypted QR from any holder, or the board admin window ("Entrar pela placa"). | Implemented (Phases 2–3, 2026-09-24; bench test pending) | lifecycle §4, §5 I–K, §11 | app `central_installation_screen.dart`, `join_from_board_screen.dart` |
| 7.3 | Channel change | `SET_CHANNEL {channel, switch_at}` down the mesh, board switches last. | Planned (undefined) | blueprint §8 | — |
| 7.4 | Firmware update (OTA) | Three signed images (board, node, leaf), one per family; the board stores the node and leaf images in `fw_store` and serves the whole site over HTTP through the mesh, one unit at a time, root last, paused by alarms; rollback on failed self-test; leafs pull on a wake when the offer rides their ACK; rollouts targetable by model / zone / unit; the tablet's Atualização screen tracks every unit and every failure. | **Step 0 done in code 2026-09-29** (`phase3-ota-brief.md`): every image signed with a key kept outside the repository (`docs/ota/signing-key.md`), the update messages in protocol §13 with host-tested codecs, every unit and the board reporting product and version. Nothing installs over the air yet (steps 1–2) | `ota-and-production-blueprint-v1.md`, `phase3-ota-brief.md` | — |
| 7.5 | Factory station | Flashes bootloader + app + identity, prints the sticker, records the unit in the factory DB; secure boot + flash encryption on production units. | Planned | OTA blueprint §5 | — |
| 7.6 | Bench tooling | Console commands, host tests (protocol vectors), hardware-in-the-loop script, failover timer, LED language for silent bench debugging (7.7). | Phase 1 firmware (LED language, host tests, timer) → Phase 1 step 4 (console, HIL) | brief §9/§11 | `siot_ui_led`, `firmware/test/host`, `tools` |
| 7.7 | LED language — traffic pulses | Decided 2026-09-23 so a walk test can be read from the LEDs alone. Role colours: white blink = setup, white solid = joining, **green flash 250 ms every 5 s = root node**, off = child node, **magenta flash 250 ms every 5 s = board**, red = alarm latched, blue blink = IDENTIFY. Traffic pulses fire **only when the unit transmits** (its own frames; on the board also every relay), never on receive: **blue 100 ms** = background frame (`HEARTBEAT`, `TOPOLOGY`, `NAME_ANNOUNCE`, `EVENT_LOG_*`, `INSTALLATION`); **blue 500 ms** = message (`EVENT`, `ACK`, `COMMAND`, `TIME_SYNC`); **cyan 500 ms** = the tablet's ACK for a frame this unit sent arrived (the only cyan). Pulses queue in order, never override. Reading a walk test: tap on a node → *blue* (sent) then *cyan* (confirmed); board → one *blue* when it forwards the event to the tablet, one *blue* when it forwards the ACK back; three blues 2 s apart and no cyan = no ACK (tablet not connected or link down). Ticks fold into a running tick; IDENTIFY suppresses pulses while it runs. | Phase 1 firmware | brief §9 (base colours) | `siot_ui_led` (`on_tx`, pulse queue) |

---

## 4. Numbers customers ask about

| Question | Answer | Where it comes from |
|---|---|---|
| How fast does an alarm reach the panel? | Budget ≤ 10 s end to end; measured ≪ 1 s on a healthy 2-level mesh. | spec §0; POC-BRIEF §7 |
| How soon do we know a device is dead? | 45 s for a powered device, 180 s for a battery detector (3 missed heartbeats). Limits: 200 s NFPA 72, 300 s EN 54-25. | spec §9.2 |
| Can an alarm be lost if the tablet is unplugged? | No: the board journals every event and the tablet backfills on reconnect; the device also repeats an active alarm every 60 s until reset. | spec §7.2, §8 |
| What if the root device fails? | Another AC device takes over automatically; target under 60 s, worst case 120 s. Alarms raised during the switch are delivered. | blueprint §7 |
| What if the board fails? | The mesh keeps running; sirens still sound on any authenticated alarm they overhear; the tablet shows a link trouble. | blueprint §7 |
| Does it need internet? | No — not for installation, operation or alarms. Internet only adds remote viewing. | blueprint rule 6 |
| How is it secured? | AES-128-CCM authenticated encryption on every frame with a per-installation key; Wi-Fi WPA2 with a per-installation password; per-unit sticker secret for provisioning; neighbouring systems are cryptographically incompatible. | spec §4, §3.1 |
| How many devices? | Mesh up to 4 levels; blueprint targets 50 units validated, 250 simulated (POC E, not yet run). | blueprint §9.5 |
| How long does installing a unit take? | ~20–30 s per unit from the phone, offline. | blueprint §3, POC-BRIEF §7 |
| Battery life of a detector? | Decided by POC D (battery pack) — not yet measured. Cadence is 60 s fixed (3 × 60 s = 180 s missing rule under the 200 s NFPA limit); rough estimate ≈ 7 months on 2 500 mAh, against standards' minimums of ≥ 1 year (NFPA 72) / ≥ 3 years (EN 54-25) to verify. | spec §12.12, blueprint §11 |
| Which standards? | Designed for UL 864 / NFPA 72 and EN 54-25 / ISO 7240-25; the board is the certifiable control unit, the tablet a supplementary annunciator. Numeric limits to be verified against purchased editions before a lab submittal. | spec §0 |

### 4.1 Scale and hardware constraints — the 250-device target (decided 2026-09-27)

Modules recommended by the supplier (2026-09-25): **ESP32-S3-WROOM-1-N8R8** (8 MB flash + 8 MB octal
PSRAM) and **ESP32-S3-WROOM-1-N4** (4 MB flash, no PSRAM). Same footprint and pinout; the R8 parts
consume GPIO 35–37, which no SempreIoT PCB uses. `firmware/build.sh` / `tools/flash.sh` know both
(`--module n8r8|n4`); `tools/flash.sh` refuses to write a build whose flash size differs from the chip.

**Decision**

| Product | Module | Why |
|---|---|---|
| Board | N8R8, **PSRAM enabled** (`CONFIG_SPIRAM=y`, octal; today off — the build summary warns) | Root of everything, OTA server (`fw_store`), event journal, device table. One or two per site: cost irrelevant. |
| AC device (siren, I/O, AC detector, repeater) | **N4**, confirmed by measurement (below); N8R8 is the fallback with no PCB or firmware change | Flash, outage storage and the leaf-manager role all fit the N4. The only open question is root RAM under load. |
| Battery detector | N4 | Never root, never relay, sleeps; PSRAM would cost standby current for nothing. |

**Constraints that led there (each one is a rule for the firmware)**

1. **Flash is not the limit.** Node image 903 KB today in a 1.875 MB slot (46 %); the fixed cost is
   Wi-Fi + lwIP + Mesh-Lite + mbedTLS, the application grows slowly; expected final size 1.2–1.4 MB,
   under the OTA blueprint's 1.75 MB cap. Board image 858 KB in a 2.375 MB slot (grown from 2 MB on
   2026-09-27 using 768 KB of the 8 MB table's spare; 32 KB spare remains, same as the node table).
2. **Outage storage lives in flash, never in PSRAM.** Whatever a unit must keep while the mesh, the
   board or its own power fails has to survive a reboot or brownout. PSRAM is volatile. Sizing: one
   event record ≈ 40 B → 64 KB holds ~1,600 events; a status snapshot every minute for 24 h ≈ 90 KB.
   Units store state changes and alarms, not heartbeats.
3. **Reserve the node journal partition now.** Partition tables never change over the air (OTA
   blueprint §8). Shrinking the two node OTA slots to the 1.75 MB cap frees 256 KB on the 4 MB table
   for a `journal` data partition. This must ship in the first fielded table, whichever module wins.
4. **The leaf manager is bounded by ESP-NOW, not by memory.** Per-leaf state (MAC, sequence, last
   seen, battery, mailbox) ≈ 128 B → all 250 leaves on one parent = 32 KB. Limits that do bind
   (`esp_now.h`, IDF 5.5.2): **20 peers total, 6 encrypted**. Rule: a parent adds a leaf as an
   unencrypted peer when it wakes, answers, drops it; SAFR does the encryption. Airtime per parent
   (hundreds of detectors waking every 60 s) is the other bound — an installer placement rule.
5. **Root throughput is small at 250 devices** (heartbeat 15 s, topology 60 s, frames ≤ 250 B):
   heartbeats ≈ 17 frames/s, topology ≈ 4 frames/s, all-250-in-alarm re-announce + ACKs ≈ 8 frames/s,
   total ≈ 30 frames/s ≈ 4 KB/s. The root copies relayed frames without decrypting them; it holds one
   TCP connection per direct child (≤ ~10) plus one to the board, never 250 of anything.
6. **The real scale risks are bursts, not steady flow — and they are the same on any module:**
   - *Reconnection storm* when the root dies: every subtree re-associates, DHCPs and reforms. This
     is the 60 s / 120 s failover target (row 2.3) and the test that matters for certification.
   - *Retry storm* when the board or tablet drops: 250 units resend ACK-required events 3× at 2 s
     then raise their own communication trouble (spec §7.2). Every node queue must be bounded so a
     long outage cannot grow memory.
   - *SoftAP fan-out*: each node admits a limited number of children; a site where one AC device is
     the only good parent for dozens of units hits that cap, not a RAM cap. Installer placement rule.
7. **One node image for both modules.** Build the node with `CONFIG_SPIRAM=y` +
   `CONFIG_SPIRAM_IGNORE_NOTFOUND=y` (both in IDF 5.5.2) so the same signed image boots on N4 and
   N8R8; partitions are found by name so a per-module table is a factory-station choice only.

**Measurements that close the decision (before a production quantity of N4 is ordered)**

| Test | How | Pass |
|---|---|---|
| Root heap at site scale | Bench-only *load mode*: each of two real nodes emits heartbeats + topology for 125 synthetic MACs at real cadence through the real mesh, board and tablet, one hour, with an OTA download in flight | root minimum free heap stays above ~100 KB |
| Failover at scale | Same load; kill the root; time reformation | < 60 s target, 120 s max (row 2.3) |
| Fleet memory margin | Add **minimum free heap + largest free block** to every `TOPOLOGY` frame (60 s) so every site reports its own margin to the tablet | continuous data, no bench needed |

If the heap test fails, the AC device purchase order changes to N8R8; nothing else does.

---

## 5. Compliance principles baked into the design

- Alarm priority over all other traffic; alarm latching until manual reset; silence ≠ reset.
- Every communication path supervised in both directions (heartbeats up, `LINK_CHECK` down).
- No alarm message lost: acknowledged delivery, re-announcement, journal + backfill, dedupe.
- Site-specific identification: neighbouring installations cannot interoperate.
- Every signal identifies the specific device (MAC + name + zone).
- The control unit (board) must enforce every mandatory behaviour with the tablet disconnected —
  today several of these still live in the tablet app; moving them to the board is Phase 1/2 work
  (§3.4, §3.5). Certification hardware (watchdog, supervised power, sounder) is outside the protocol.

---

## 6. Development status and roadmap (one line per phase)

| Phase | Content | State |
|---|---|---|
| POC round 1 | Board + 2 AC nodes + provisioning from the phone + SAFR over Mesh-Lite + failover, on the bench | Done on the bench (Sep 2026); measurements not written up |
| **Firmware Phase 1 — Network core** | Permanent `firmware/` tree, SAFR, identity, provisioning, mesh, serial, board root duties, supervision, host/HIL tests; freeze at `fw-0.1.0` | Steps 1–3 of brief §15 built and running on the bench (2026-09-23: provisioning, mesh, tap → tablet → ACK, LED traffic language); step 4 (supervision + persistence) next |
| Phase 2 — Battery detectors | ESP-NOW leaf protocol, deep sleep, parent mailbox, power/tamper inputs | Protocol written (spec v3.4 §12, 2026-09-28); plan in `docs/phases-development/phase2-leaf-brief.md`; firmware not started |
| Sensing & alarm engine | ADPD188BI / HDC2080, thresholds, sirens, cause-and-effect, board-side latching | Planned |
| OTA & production | Signed images, board-served mesh OTA, leaf pull, factory station, secure boot | Blueprint written; **plan: `docs/phases-development/phase3-ota-brief.md` (2026-09-28)**; nothing coded |
| App | Remote events to viewers, walk-test report, maintenance flows | Planned |

---

## 7. Document index — which file answers what (and who wins on conflict)

Order of authority: **1 → 2 → 3**; a POC brief or a phase brief never overrides the protocol or the
blueprint.

| # | File | What it is |
|---|---|---|
| 1 | `docs/safr/protocol-safr-v3.md` | The wire format, crypto, ACK/retry, timings, compliance tags, test vectors. Single source of truth for anything on the wire. |
| 2 | `docs/others/system-blueprint-v1.md` | The rules, vocabulary, installation cases, network formation, operation, failures, maintenance, engineering order. |
| 2b | `docs/others/installation-lifecycle-v1.md` | Installation lifecycle: device table, key custody, every scenario (any install order, several installers, add/replace/retire/rename, lost phone, dead board/tablet, re-key), survey mode, gating, phase map. Below the blueprint, above the briefs. |
| 2c | `docs/others/installation-guide.md` | The practical step-by-step for installers and operators (create, share, configure units and board, survey, tablet in service, later changes, recovery), with each step tagged by the lifecycle phase that delivers it. Not normative. |
| 3 | `docs/ota/ota-and-production-blueprint-v1.md` | Images, partition tables, OTA flows, factory station, secure boot. Identity §4.1 superseded by the Phase 1 brief (id + pop). |
| 3a | `docs/ota/signing-key.md` | **Where the firmware signing key is** (outside the repository), its fingerprint, how the build uses it, what stage 1 protects, how to back it up and how to replace or regenerate it — and what that costs (a cable flash of every unit). |
| 4 | `docs/phases-development/firmware-phase1-network-brief_3.md` | What Phase 1 of the product firmware builds, the `firmware/` tree, exit checklist, open items, implementation order. |
| 4b | `docs/phases-development/phase2-installation-lifecycle-brief.md` | The installation-lifecycle implementation plan (Phases 0–4): what was built per area, the deploy recipe, the bench checklist, and the Phase 4 items that are deliberately not done. |
| 4c | `docs/phases-development/phase2-leaf-brief.md` | The battery-detector (leaf) plan: decisions behind protocol §12, the bench without leaf hardware (deep sleep on devkits, mocked sensors), cadence vs standards and battery arithmetic, step order and exit checklist. |
| 4d | `docs/phases-development/phase3-ota-brief.md` | The OTA plan: decisions on top of the OTA blueprint (families, model targeting, HTTP pull, leaf offer in the ACK, stage-1 signing), the protocol additions to write first (v3.5), steps, the Atualização screen, bench checklist O1–O15, targets, risks. |
| 5 | `docs/others/app-sempreiot-central.md` | The Flutter app as it is: modes, providers, DB, SAFR pipeline, cloud, wizard. (Table catalogue of record is §3.6.1 of this file.) |
| 6 | `docs/spec/definition-central.md`, `docs/spec/definition-detector.md` | PCB GPIO maps, sensors, UART/USB. |
| 6b | `docs/devices/board.md`, `docs/devices/node.md`, `docs/devices/leaf.md` | One page per **family** (board, AC device / node, battery detector / leaf): definition, hardware, rules, every functionality row that touches it with status, modes and LEDs, messages, storage, numbers, what is missing. Compiled from this file — this file wins on conflict. |
| 6c | `docs/devices/siren.md`, `docs/devices/push-button-station.md`, `docs/devices/smoke-detector.md` | One page per **product** (§2.1): what the model inherits from its family today, the planned feature component, rules, open items. |
| 7 | `pocs/POC-BRIEF.md`, `pocs/APP-BRIEF.md`, `pocs/README.md` | Round-1 POC contracts and the bench LED language. |
| 8 | `CLAUDE.md` | Toolchain and coding rules for every session (IDF 5.5.2, header-before-docs). |
| 9 | this file | Functionality catalogue, customer numbers, status, index. |

---

## 8. Glossary (use these words and no others — blueprint §0)

**Board** — the control unit attached to the tablet; raises the installation Wi-Fi; never a mesh node.
**Tablet / Central** — the operator's panel app, USB to the board. **AC device** — mains-powered mesh
node (siren, I/O, AC detector, repeater); root-capable. **Battery detector / leaf** — sleeping
ESP-NOW detector; wakes every 60 s, talks only to its bound **parent** (an AC device), never root, never relay (spec §12). **Root** — the AC device currently connected to the board's AP, chosen by Mesh-Lite.
**The code** — the installation bundle (`SYSTEM_ID`, `NET_SSID`, `NET_PSK`, `SAFR_PSK`, `CHANNEL`,
`MESH_ID`). **Sticker** — factory QR `{id, mac, pop}`. **Setup network** — `SIOT-SETUP-<id>`, raised
while unprovisioned. **SAFR** — Secure Alarm Frame Relay, the protocol. **Installer / Viewer app** — the
phone app's offline and online functions. **ALARM / ALERT / TROUBLE / RESTORE** — the four event
severities (3 / 2 / 1 / 0). **Latch** — an alarm held on the panel until operator RESET.
