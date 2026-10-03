# SempreIoT — Board (the control unit)

_2026-09-28. One page per device type, compiled from `docs/sempreiot-system-reference.md` (rows quoted as
"ref 1.5" etc.), the blueprint, the lifecycle spec, the protocol and the Phase 1 brief. When this page and
the reference disagree, the reference wins; fix this page. Sibling pages: `node.md` (AC device),
`leaf.md` (battery detector)._

---

## 1. Definition

The **board** is the control unit of an installation: the device attached to the tablet by USB. It
raises the installation's Wi-Fi access point, bridges every frame between the mesh and the tablet,
acknowledges commands, journals every event, and will latch alarms and supervise devices on its own.
It is the piece that is certified as the *control unit* (UL 864 / ISO 7240-2); the tablet is a
supplementary annunciator (ref §1, §2, §4).

What the board is **not** (blueprint §0, rule 2):

- **Not a mesh node.** It runs no Mesh-Lite. Its access point is the *router* the mesh hangs from.
- **Never the root.** The root is always an AC device, chosen by Mesh-Lite.
- **Not a Wi-Fi client.** It runs AP-only; its `SRC_MAC` in SAFR is still its STA MAC (brief §4.1).

Vocabulary (blueprint §0 — use these words and no others): *board*, *tablet / central*, *AC device*,
*battery detector / leaf*, *root*, *the code*, *sticker*, *setup network*. In SAFR frames the tablet is
the reserved MAC `00:00:00:00:00:01`; the board reports itself as the layer-0 device.

## 2. Hardware

| Item | Value | Source |
|---|---|---|
| Module | **ESP32-S3-WROOM-1-N8R8** — 8 MB flash + 8 MB octal PSRAM | ref §2, §4.1 (decided 2026-09-27) |
| PSRAM | To be enabled (`CONFIG_SPIRAM=y`, octal); today off, the build summary warns | ref §4.1 |
| Power | Mains + battery (ACOK GPIO 5, BOOST 6, CHG 7 on the PCB) | ref §2, `docs/spec/definition-central.md` |
| Tablet link | Native USB-Serial-JTAG (GPIO 19/20) in the product; **UART0 (GPIO 43/44) on every bench build** — only `--bench` moves the link to USB so the console can use UART0 | ref 2.6, `firmware/README.md`, `tools/pinmap/pinmap.yaml` |
| LED | RGB on GPIO 14 / 47 / 48 (LEDC, 5 kHz, active-high) | `pinmap.yaml` |
| Button | GPIO 21, pull-up, active low (RST/TESTE) | `pinmap.yaml` |
| Flash layout (8 MB) | `nvs` 24 KB · `otadata` · `phy_init` · `ota_0` / `ota_1` 2.375 MB each · **`fw_store` 3 MB** (the node image it will serve over the mesh) · `nvs_factory` 32 KB · `coredump` 64 KB · 32 KB spare | OTA blueprint §1.2 |
| Image today | 858 KB in a 2.375 MB slot | ref §4.1 |
| Bench variant | 4 MB devkits: `partitions_board_4mb.csv` via `firmware/build.sh board --flash 4mb` | `firmware/README.md` |
| Model string | `CONFIG_SIOT_DEV_MODEL="SIOT-BOARD-01"` — the `SIOT-BOARD-` prefix is how the app wizard recognises a board | brief §4.1 |

Why 8 MB: `fw_store` holds the node image plus manifest so the board can update the whole site without
the tablet in the loop; the journal and the device table also live here (OTA blueprint §1.4).

## 3. Rules that bind the board (blueprint §1)

1. The board raises the installation Wi-Fi. Nothing else does; the tablet never does.
2. The board is never a Mesh-Lite node; root is always an AC device.
3. The code reaches the board exactly like any other unit: sticker → setup network → the app pushes it
   (Case A), or the tablet arms it over USB on the pop-keyed setup channel (Case B).
4. The tablet always learns the **roster** from the board over USB. The board never sends the **code**
   over USB except to a tablet that proves the board's own `pop` (`GET_CODE`).
5. A unit is "installed" only when the board has heard an authenticated frame from it.
6. SAFR v3 stays end-to-end on every hop; the board forwards frames unchanged and never decrypts what
   it relays (it does decrypt what is addressed to it).
7. The board must enforce every mandatory behaviour with the tablet disconnected (ref §5). Several of
   these still live in the tablet today — see §9.

## 4. What the board does — functionality and status

Status words are the reference's: `Implemented` · `POC` · `Planned` · `Open`.

### 4.1 Identity, installation, provisioning

| Ref | Function | Board's part | Status |
|---|---|---|---|
| 1.1 | Factory identity + sticker | `id` + `pop` in the read-only `nvs_factory` partition; QR `{id, mac, pop}` | POC → Phase 1 |
| 1.2 | The code | Holds the same bundle as every unit: `SYSTEM_ID`, `NET_SSID = SIOT-<hex4>`, `NET_PSK`, `SAFR_PSK`, `CHANNEL`, `MESH_ID` | POC (firmware) |
| 1.3 | Setup network | Unprovisioned: raises `SIOT-SETUP-<id>` (WPA2 = `pop`) with the HTTP server | POC |
| 1.4 | Provisioning handshake | `/info` → `/identify` (HMAC of `pop`) → `/provision` (AES-CCM envelope) → `/enroll` hint list; stores code + installation name, reboots | POC |
| 1.5 | **Device table** | One entry per MAC: `expected / online / missing / retired`, name, zone, role, flags; built from authenticated traffic, edited by the tablet; cap 120 in the 24 KB `nvs` | Implemented (2026-09-24, bench pending) |
| 1.6 | Tablet reads the installation | Answers `GET_INSTALLATION` / `GET_DEVICE_TABLE` with identity, SSID, channel, name, table — never the secrets. Answers `GET_CODE` **only on the setup channel** after the operator typed the board's `pop` | Implemented (bench pending) |
| 1.7 | Case A / Case B | A: provisioned from a phone like any unit. B: armed by the tablet with `SET_INSTALLATION` on the setup channel, ACKs, reboots on the new SSID | A: POC · B: Implemented (bench pending) |
| 1.8 | Factory reset | Button held 5 s: wipes `siot_inst` (the code, names), keeps identity, back to setup mode | POC |
| 1.9 | Device naming | Relays `NAME_ANNOUNCE` up; applies `SET_DEVICE` to its table (sets `ANNOTATED`, `PENDING_RENAME` if the unit is not online) and re-originates it to the unit on its next frame — for a leaf, on its first frame through **any** parent, which is what refills the current parent's mailbox (spec §12.5) | Implemented (bench pending) |
| 1.10 | Survey mode | Not a prober. **Answers** `PARENT_PROBE purpose = 1` with `PARENT_OFFER {LAYER 0x00}` over raw ESP-NOW on the installation channel and shows the 1 s colour verdict; node-to-board reach is the link that matters most | Implemented, bench-verified 2026-09-24 |
| 1.11 | Provisioning dedup | `/provision` answers `409 already_stored` after the first success | Implemented |
| 1.12 | **Admin window** | Double tap: installation AP suspended, `SIOT-SETUP-<id>` for 5 min with `GET /info`, `/identify`, `GET /code` (the code encrypted for the sticker); closes 2 s after a delivery; refused within 10 min of an ALARM; LED white blink meanwhile. The root loses the board for the window | Implemented (bench pending) |

### 4.2 Network

| Ref | Function | Board's part | Status |
|---|---|---|---|
| 2.1 | Installation access point | Raises `NET_SSID` / `NET_PSK` on the fixed channel (1 / 6 / 11), static IP `192.168.4.1`, DHCP on, `max_connection` 8 | POC |
| 2.4 | Uplink path | Root → board over **TCP `:5340`** (one client = the current root, newest wins, keepalive 2 s / 1 s / 3) → tablet over serial. Frames forwarded byte-for-byte | POC |
| 2.5 | Downlink path | Tablet → board → root; the board ACKs `COMMAND` / `TIME_SYNC` itself before relaying, and **forwards the tablet's ACKs down** so a node sees its uplink confirmed | POC + Phase 1 fix |
| 2.6 | Tablet link | Raw SAFR bytes, 115200 8N1; `CONFIG_ESP_CONSOLE_NONE` so no text pollutes the link; the ROM boot banner still precedes the stream and the tablet resyncs on SOF + LEN + CRC | POC |
| 2.8 | Site separation | Distinct `NET_PSK` (cannot join), distinct `SYSTEM_ID` (dropped before decryption), distinct `SAFR_PSK` (CCM fails) | POC |

### 4.3 Protocol and delivery assurance

| Ref | Function | Board's part | Status |
|---|---|---|---|
| 3.1 | Authenticated frames | Every frame it originates is AES-128-CCM under the installation key; `LEN ≤ 250` | POC |
| 3.2 | Replay protection | Remember `(BOOT_CTR, MSG_CTR)` per `SRC_MAC` and drop older frames | Planned Phase 1 (only the tablet has it) |
| 3.3 | Acknowledged delivery | ACKs downlink commands as the mesh's confirmer; the tablet ACKs uplink `F_ACK_REQ` and the board relays that ACK down | POC |
| 3.6 | **Event journal + backfill** | Stores every uplink `EVENT` `{jrn_seq, mac, payload}`; answers `EVENT_LOG_REQ` with `EVENT_LOG_DATA`, deduped by the tablet; ≥ 64 entries. Leaf events replayed from a leaf outbox arrive with their original timestamps and sequence numbers and are journaled in order (spec §12.6) | POC (RAM ring) → Phase 1 (flash-persisted, monotonic `JRN_SEQ`) |
| 3.7 | Severity priority | ALARM > supervisory > trouble > restore in the transmit queue | Planned Phase 1 (POC has one in-flight critical frame) |
| 3.8 | Time synchronisation | Receives `TIME_SYNC` from the tablet on link-up and hourly, ACKs, forwards down the mesh, and must **adopt the epoch itself** (its own HEARTBEAT timestamp is 0 today) | POC (forward) · Planned Phase 1 (board clock) |

### 4.4 Supervision

| Ref | Function | Board's part | Status |
|---|---|---|---|
| 4.1 | Heartbeats / topology | Emits its own `HEARTBEAT` every 15 s and `TOPOLOGY` every 60 s with `LAYER 0`, `NODE_ROLE root`, `PARENT_MAC` = the tablet, children = AC devices heard | POC |
| 4.2 | Device-missing trouble | Marks an entry `missing` after 3 × its interval (45 s AC, 180 s for a leaf at its fixed 60 s, unknown role → 45 s). **Root fast path (v3.3):** TCP keepalive reaps a dead root in ~5 s; the board marks it missing and pushes the full `DEVICE_TABLE` unsolicited; the tablet takes it as authoritative | Implemented (table + fast path); synthetic TROUBLE from the board is Phase 1 step 4 |
| 4.3 | Downlink supervision | ACKs the tablet's `LINK_CHECK` every 30 s and keeps it off the mesh (2026-10-03: before, every node ACKed it too) | Implemented (bench pending) |
| 4.5 | Self-reporting both ways | Its `HEARTBEAT` goes to the tablet **and** is broadcast down the mesh every 15 s; it is the frame a joined node uses to know the board is there (LED online within 15 s of joining, tablet or not); sent the moment a root connects | Implemented (2026-09-27) |

### 4.5 Alarm handling and operator actions

| Ref | Function | Board's part | Status |
|---|---|---|---|
| 5.1 | Alarm latching | Must latch every ALARM until operator `RESET` regardless of the tablet | Planned (the tablet latches today) |
| 5.2 | SILENCE / RESET | Relays the commands into the mesh; ACKs them | POC |
| 5.3 | Test button | **Short press on the board broadcasts `COMMAND TEST`** so every node raises its own `MANUAL_TEST` — a one-button site-wide walk test; the board raises no event of its own (decided 2026-09-23). Hold ≥ 5 s = factory reset | Phase 1 firmware |
| 5.6 | Sirens, cause-and-effect | Sends `COMMAND SOUND` to selected sirens; drives its own sounder | Planned (`SOUND` undefined) |
| 5.8 | Power troubles | AC lost / on battery / charging from GPIO 5 / 6 / 7 into `PWR_FLAGS` | Planned (only `AC_OK` read today) |

### 4.6 Maintenance, updates, production

| Ref | Function | Board's part | Status |
|---|---|---|---|
| 7.1 | Lifecycle commands | `SET_DEVICE`, `RETIRE` / `UNRETIRE`, `REPLACE_DEVICE`, `DECOMMISSION`, `FORGET_DEVICE`, `GET_DEVICE_TABLE` — board-only ones are answered on the serial link and never relayed | Implemented (bench pending) |
| 7.2 | Replace the board | Provision the new one from any code holder, or arm it from the tablet (Case B); it rebuilds its table from what it hears; the tablet can "Reenviar nomes à placa" | Implemented (bench pending) |
| 7.3 | Channel change | `SET_CHANNEL {channel, switch_at}` down the mesh; the board switches **last** | Planned (undefined) |
| 7.4 | OTA | Receives an image from the tablet over USB (protocol §13.3; the link goes to 921600 for the push): its own → the inactive slot, verified, restart, self-test (120 s to hear the tablet), confirm or roll back and say so; a node or leaf image → verified and stored in `fw_store`. Serving the site over HTTP, root last, paused by any alarm = step 2 | **Push + self-update done in code 2026-09-29, bench pending (O1–O5)**; rollout not started |
| 7.5 | Factory station | Flashed with bootloader + app + `nvs_factory` identity; sticker printed | Planned |
| 7.7 | LED language | See §5 | Phase 1 firmware |

## 5. Modes, boot and LED language

Boot (brief §3): NVS → identity (`nvs_factory`; none → `UNPROVISIONED_FACTORY`, red slow) → pin map →
LED/button → event bus → load `siot_inst` → SAFR init when a code exists → **no code: setup mode;
code: coordinator** (installation AP + TCP `:5340` + serial link + root duties).

| Mode | Trigger | LED | Radio |
|---|---|---|---|
| Setup | No code, or after factory reset | **white blink** (the only white blink) | `SIOT-SETUP-<id>`, HTTP provisioning server; AC units keep it up indefinitely |
| Normal (serving) | Code stored | **magenta flash 250 ms every 5 s** | Installation AP on `CHANNEL`; TCP server; serial link |
| Admin window | Double tap in normal mode | white blink for ≤ 5 min | Installation AP **suspended**; `SIOT-SETUP-<id>` up for `/info`, `/identify`, `/code` |
| Factory-reset armed | Button held ≥ 5 s | white solid, then reboot into setup | — |
| Unprovisioned factory | No `id` / `pop` in `nvs_factory` | red slow | — |

Traffic pulses (ref 7.7; fire only when the board transmits or relays, never on receive): **blue 100 ms** =
background frame (`HEARTBEAT`, `TOPOLOGY`, `NAME_ANNOUNCE`, `EVENT_LOG_*`, `INSTALLATION`); **blue 500 ms**
= message (`EVENT`, `ACK`, `COMMAND`, `TIME_SYNC`). Reading a walk test at the board: one blue when it forwards
the node's event to the tablet, one blue when it forwards the ACK back. The board never shows cyan (that is
"my own frame was ACKed by the tablet" and the board originates no ACK-required uplink).

## 6. Messages — what the board originates, answers and relays

| Direction | Message | Board behaviour |
|---|---|---|
| Up (own) | `HEARTBEAT` 0x02 every 15 s, `TOPOLOGY` 0x03 every 60 s | Layer 0, role root, parent = tablet; HEARTBEAT also broadcast **down** |
| Up (own) | `INSTALLATION` 0x09 | Reply to `GET_INSTALLATION`; legacy view for pre-v3.2 tablets, encoded from the first table entries |
| Up (own) | `DEVICE_TABLE` 0x0B, paged | Reply to `GET_DEVICE_TABLE`; **unsolicited full push** when the root's TCP session drops |
| Up (own) | `CODE` 0x0C | Reply to `GET_CODE`, setup channel only, never on the mesh |
| Up (own) | `EVENT_LOG_DATA` 0x08 | Reply to `EVENT_LOG_REQ` from the journal |
| Up (own) | `ACK` 0x04 | For every downlink `COMMAND` / `TIME_SYNC` before relaying; `DETAIL` byte on the v3.2 commands (`0x01` unknown MAC … `0x06` not in setup mode) |
| Up (relay) | `EVENT`, `HEARTBEAT`, `TOPOLOGY`, `NAME_ANNOUNCE`, `ACK` from nodes | Forwarded byte-for-byte; `EVENT` also journaled; frames from a `retired` MAC dropped after CCM |
| Down (relay) | `COMMAND` 0x05, `TIME_SYNC` 0x06, tablet `ACK` | Into the mesh via the root; board-only commands (`GET_INSTALLATION`, `RETIRE`, `UNRETIRE`, `REPLACE`, `FORGET`, `GET_DEVICE_TABLE`, `GET_CODE`, `SET_INSTALLATION`) are **never relayed** |
| Down (own) | `HEARTBEAT` | Every 15 s and the moment a root connects — the tree's proof that the board is there |
| Down (own) | `COMMAND TEST` broadcast | On a short press of the board button (Phase 1) |
| ESP-NOW | `PARENT_OFFER` 0x0E, `LAYER 0x00` | Answer to a survey probe; raw ESP-NOW with data-type byte `0xD2` (the board has no Mesh-Lite) |

Setup channel (spec §3.1): header `SYSTEM_ID 0x0000`, key derived from the board's `pop`; used by
`SET_INSTALLATION` (Case B), `GET_CODE` and `CODE` only.

## 7. Storage

| Where | What | Written |
|---|---|---|
| `nvs_factory` / `siot_fact` | `id`, `pop` (16..63 chars) — read-only in firmware, survives a full erase of `nvs` | Factory station only |
| `nvs` / `siot_inst` | `code` blob (`system_id`, `net_ssid`, `net_psk`, `safr_psk[16]`, `channel`, `mesh_id`, `name`, `zone`), `boot_ctr`, `dev_seq` | Provisioning, `SET_INSTALLATION`; erased by factory reset |
| `nvs` device table (`siot_devtab`) | Per MAC: `role`, stored state (`expected` / `retired`), `flags`, `first_seen`, `name[33]`, `zone[17]`; `online` / `missing` derived from `last_seen` in RAM; 3 NVS entries per unit, cap `CONFIG_SIOT_DEVTAB_CAP` = 120 | First sighting and operator actions only |
| Journal | `{jrn_seq, mac, payload[17]}` per uplink `EVENT`; 64-entry RAM ring today | Every uplink EVENT; flash-persisted in Phase 1 step 4 |
| `fw_store` (3 MB FAT, wear-levelled, 8.3 names) | `/fw/node.bin`, `/fw/leaf.bin`, each with `/fw/<family>.inf` (version, size, SHA-256, written last); `<family>.tmp` while a push runs; `rollout.json` with step 2 | `siot_ota_board` (2026-09-29). The 4 MB bench table has no `fw_store`: that board updates itself only |

## 8. Numbers

| Quantity | Value | Source |
|---|---|---|
| Own HEARTBEAT / TOPOLOGY cadence | 15 s / 60 s | spec §7.3, §7.4 |
| Dead root detected | ~5 s (TCP keepalive 2 / 1 / 3) | spec §9.2 v3.3 |
| Device missing | 3 × interval: 45 s AC device, 180 s leaf at 60 s | spec §9.2 |
| Tablet's link rule against the board | valid frame within 20 s, else "stalled" | spec §9.3 |
| `LINK_CHECK` from the tablet | every 30 s, trouble after 3 unconfirmed | spec §9.3 |
| Admin window | 5 min; refused within 10 min of an ALARM; closes 2 s after a delivery | lifecycle §11 |
| AP `max_connection` | 8 (bounds root election, not the mesh) | brief §8 |
| TCP `:5340` | one client, the current root | brief §8 |
| Device table cap | 120 (250 needs a partition decision in the OTA phase) | lifecycle §3.1 |
| Root throughput at 250 devices | ≈ 30 frames/s ≈ 4 KB/s through the board | ref §4.1 |
| Serial | 115200 8N1 (≈ 11 KB/s); OTA push needs 921600 | spec §2, OTA §1.4 |

## 9. What is still missing on the board (ordered as Phase 1 step 4 lists it)

1. Flash-persisted journal with monotonic `JRN_SEQ` (ref 3.6).
2. Board wall clock adopted from `TIME_SYNC` (ref 3.8, brief §14 item 12); `first_seen` in the table is 0 until then.
3. Replay check `(BOOT_CTR, MSG_CTR)` per sender (ref 3.2).
4. ALARM-first transmit queue (ref 3.7).
5. Synthetic `TROUBLE` "device missing" raised by the board, not only by the tablet (ref 4.2).
6. Alarm latching in the board with the tablet disconnected (ref 5.1, §5).
7. Board button short press → `COMMAND TEST` broadcast (ref 5.3).
8. `CONFIG_SPIRAM=y` on the N8R8 (ref §4.1).
9. Sirens / `COMMAND SOUND`, own sounder and fire/fault/power LEDs (ref 5.6; blueprint §5.3).
10. `SET_CHANNEL`, the OTA rollout (HTTP server, scheduler — step 2; the push and the self-update are written), factory station (ref 7.3–7.5).
11. Bench passes 1–10, 12–14 of the lifecycle brief (device table, `GET_CODE`, rename, Case B, admin window…).

## 10. Where it lives

- App: `firmware/apps/board` (`app_main.c`, `sdkconfig.defaults`, `partitions_board.csv`, `partitions_board_4mb.csv`).
- Components: `siot_coordinator` (`siot_coordinator.c` root duties, `coord_devtable.c`, `coord_installation.c`,
  `coord_setup.c` setup channel, `coord_admin.c` admin window), `siot_link` (`link_mesh_board.c` AP + TCP server,
  `link_serial.c`), `siot_devtab`, `siot_provisioning`, `siot_survey`, `siot_hal_serial`, `siot_ui_led`, `siot_ui_button`.
- Build / flash: `firmware/build.sh board [--flash 4mb] [--bench]`, `tools/flash.sh board <port> …`.
- Reference implementation (read-only): `pocs/board`, `mocked-device/`.
- Specs: reference §2, §3, §4.1, §5; blueprint §0–§8; lifecycle §3, §4, §11; protocol §1, §2, §7.3, §7.5, §7.6,
  §7.10–§7.13, §8, §9; Phase 1 brief §3, §4, §6.5, §8; OTA blueprint §1.2, §1.4, §3; PCB map `docs/spec/definition-central.md`.
