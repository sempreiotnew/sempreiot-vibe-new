# SempreIoT — Node (AC device: siren, I/O module, AC detector, repeater)

_2026-09-28. One page per device type, compiled from `docs/sempreiot-system-reference.md` (rows quoted as
"ref 2.2" etc.), the blueprint, the lifecycle spec, the protocol and the Phase 1 brief. When this page and
the reference disagree, the reference wins; fix this page. Sibling pages: `board.md`, `leaf.md`._

---

## 1. Definition

An **AC device** is any mains-powered unit of the installation: siren, I/O module, AC-powered detector,
repeater. In the firmware and the app it is the **node**: a Mesh-Lite node, always associated, and
**root-capable**. One firmware image (`sempreiot-node`) serves every AC device type (ref §2).

Three words that describe the same hardware in different states (blueprint §0, spec §1):

| Word | Meaning |
|---|---|
| **AC device / node** | The unit itself. Mesh-Lite node under the board's access point, up to 4 levels deep. |
| **Root** | The AC device currently connected *directly* to the board's access point (level 1). Chosen automatically by Mesh-Lite; replaced automatically when it dies. There is one root per installation. |
| **Relay / child node** | An AC device at level ≥ 2, joined under the root or another node. Forwards its subtree's traffic and re-broadcasts downlink. |

What a node is **not**: never the control unit (it does not latch, journal or supervise for the site);
never the installation's access point (it raises a SoftAP only as a Mesh-Lite parent for deeper nodes);
never a leaf (it does not sleep). Blueprint rule 10: root-capable = on AC. A site with no AC device has no
mesh.

## 2. Hardware

| Item | Value | Source |
|---|---|---|
| Module | **ESP32-S3-WROOM-1-N4** — 4 MB flash, no PSRAM. N8R8 is the fallback with no PCB or firmware change if the root-heap test fails | ref §2, §4.1 (decided 2026-09-27) |
| Power | Mains, with the PCB's battery inputs (ACOK GPIO 5, BOOST 6, CHG 7) reported in `PWR_FLAGS` | spec §7.1.3, `docs/spec/definition-detector.md` |
| LED | RGB on GPIO 14 / 47 / 48 (LEDC, 5 kHz, active-high) | `tools/pinmap/pinmap.yaml` |
| Button | GPIO 21, pull-up, active low (TEST short press / factory reset 5 s hold) | `pinmap.yaml` |
| Relay | GPIO 12 (`RELAY_SET`) — Planned | ref 5.7 |
| Sensors (AC detector) | ADPD188BI smoke + HDC2080 temperature on I2C GPIO 1 / 2, wake on GPIO 4 — Planned | ref 5.5 |
| UART0 | GPIO 43 / 44: flash and the text console (nodes only; never on the board's tablet port) | `pinmap.yaml`, brief §3 |
| Flash layout (4 MB) | `nvs` 24 KB · `otadata` · `phy_init` · `ota_0` / `ota_1` 1.875 MB each · `nvs_factory` 32 KB · `coredump` 64 KB · 32 KB spare. A 256 KB `journal` partition is to be reserved by shrinking the slots to the 1.75 MB cap before the first fielded table | OTA blueprint §1.1, ref §4.1 item 3 |
| Image today | 903 KB (46 % of the slot); cap 1.75 MB enforced by CI | ref §4.1 |
| Model string | `CONFIG_SIOT_DEV_MODEL="SIOT-NODE-01"` | `sdkconfig.defaults` |
| One image for both modules | Build with `CONFIG_SPIRAM=y` + `CONFIG_SPIRAM_IGNORE_NOTFOUND=y` so the same signed image boots on N4 and N8R8 | ref §4.1 item 7 |

## 3. Rules that bind a node (blueprint §1, ref §4.1)

1. Root is always an AC device, chosen by Mesh-Lite — never forced from the app.
2. SAFR v3 is end-to-end on every hop; Mesh-Lite only carries bytes. The root copies relayed frames
   without decrypting them.
3. Retries are SAFR's (fresh `MSG_CTR`); never `esp_mesh_lite_try_sending_msg()` for SAFR frames.
4. A node is "installed" only when the board has heard an authenticated frame from it; the phone never
   shows "online", only `stored`.
5. Every node queue is bounded so a long outage cannot grow memory (retry storm, ref §4.1 item 6).
6. Outage storage goes in flash, never in PSRAM: units store state changes and alarms, not heartbeats.
7. Giving up on a critical event is not permitted (spec §7.2): after the fast retries the node raises its
   own `COMM_FAULT` and keeps going.

## 4. What a node does — functionality and status

### 4.1 Identity, installation, provisioning

| Ref | Function | Node's part | Status |
|---|---|---|---|
| 1.1 | Factory identity + sticker | `id` + `pop` in `nvs_factory`; QR `{id, mac, pop}` | POC → Phase 1 |
| 1.2 | The code | Stores the full bundle; nothing is derived on the device | POC |
| 1.3 | Setup network | Unprovisioned: `SIOT-SETUP-<id>` (WPA2 = `pop`), HTTP server; AC units keep it up indefinitely | POC |
| 1.4 | Provisioning handshake | ~20 s from the phone, offline: `/info` → `/identify` → `/provision {envelope, name, zone}` → `stored`; reboots with the code and its own name | POC |
| 1.7 | Case A / Case B | A: provisioned with no board on site, waits in "finding the network"; B: joins at once and goes online | POC |
| 1.8 | Factory reset | Hold 5 s: erases `siot_inst`, keeps identity, white blink | POC |
| 1.9 | Device naming | Sends `NAME_ANNOUNCE` (name, zone, **role byte**) once after joining — only once a path to the board exists. On `SET_DEVICE` addressed to it: stores name/zone in NVS, ACKs, re-announces | Implemented (bench pending) |
| 1.10 | **Survey mode** | TEST on a provisioned node with **no path to the board**: broadcasts `PARENT_PROBE purpose = 1` four times 1.2 s apart over Mesh-Lite's ESP-NOW layer; blinks once per answering unit in that link's colour; passive nodes answer with `PARENT_OFFER` and show 1 s green / yellow / red | Implemented, **bench-verified 2026-09-24** |
| 1.11 | Provisioning dedup | `/provision` → `409 already_stored` after the first success | Implemented |
| 7.1 | Decommission | `DECOMMISSION` accepted only if `DST_MAC == own MAC == ARGS.mac`: ACK, wait ≈ 300 ms, erase `siot_inst`, reboot into setup mode | Implemented (bench pending) |

### 4.2 Network

| Ref | Function | Node's part | Status |
|---|---|---|---|
| 2.2 | Self-forming mesh | Boots, reads the code, starts Mesh-Lite with router = `NET_SSID` / `NET_PSK`, mesh id, node type root-or-child, max level 4, fixed channel. Nodes that see the board's AP compare RSSI; the best stays root, the rest join under it | POC |
| 2.3 | **Root failover** | If the root dies another AC device becomes root; the mesh also survives the board being off (nodes form a mesh among themselves) and re-homes when it returns. Target < 60 s, max 120 s. **v3.3:** a node whose level changed re-sends `HEARTBEAT` + `TOPOLOGY` only once the new path is proven (root: board session up; child: a downlink frame arrived), then restarts its timers | POC (numbers not recorded) · announce-on-proven-path Implemented |
| 2.4 | Uplink path | Own and relayed frames → root (Mesh-Lite raw message to root) → board over TCP `:5340` (root only) | POC |
| 2.5 | Downlink path | Root receives from the board, broadcasts to children; **every node re-broadcasts one hop further and dedupes** by MSG_ID; acts only on frames addressed to it or broadcast | POC |
| 2.7 | ESP-NOW parent for leafs | Answers `PARENT_PROBE purpose = 0` when ONLINE; holds a per-leaf **mailbox** and sets the ACK `PENDING` bit; stores-and-forwards a leaf's ALARM / TROUBLE with SAFR retries until the board ACKs | Planned Phase 2 (wire format not written) |
| 2.8 | Site separation | Wrong `NET_PSK` cannot join; wrong `SAFR_PSK` fails CCM; other `SYSTEM_ID` dropped before decrypt | POC |

### 4.3 Protocol and delivery assurance

| Ref | Function | Node's part | Status |
|---|---|---|---|
| 3.1 | Authenticated frames | AES-128-CCM, 12-byte nonce from MAC + `BOOT_CTR` + `MSG_CTR`; `BOOT_CTR` and `DEV_SEQ` persisted in NVS (the POC randomised them) | POC → Phase 1 |
| 3.2 | Replay protection | Drop older `(BOOT_CTR, MSG_CTR)` per sender | Planned Phase 1 |
| 3.3 | Acknowledged delivery | ALARM / TROUBLE (and `MANUAL_TEST` by default, brief §14 item 3) carry `F_ACK_REQ`; 3 retries 2 s apart, same MSG_ID, fresh `MSG_CTR`; then local `COMM_FAULT` TROUBLE, never silence | POC |
| 3.4 | Alarm re-announcement | Active ALARM re-sent at least every 60 s (`F_RETX`, same `DEV_SEQ`) until `RESET` | POC |
| 3.5 | Event identity | Every EVENT carries `DEV_SEQ`; receivers dedupe | POC |
| 3.7 | Severity priority | ALARM-first transmit queue | Planned Phase 1 |
| 3.8 | Time sync | Adopts `TIME_SYNC` relayed from the board; timestamps become wall-clock | POC |

### 4.4 Supervision

| Ref | Function | Node's part | Status |
|---|---|---|---|
| 4.1 | Heartbeats / topology | `HEARTBEAT` every 15 s (uptime, `PWR_FLAGS`, battery, temp, RSSI to parent, parent MAC, layer); `TOPOLOGY` every 60 s and on any child change (role, layer, parent, children with RSSI). Add min free heap + largest free block to `TOPOLOGY` for fleet memory margin | POC · heap fields Planned |
| 4.2 | Missing | A node cannot know it is missing — only the board can. Silent 45 s → the board marks it missing | Implemented (board) |
| 4.5 | **Board supervision, node side (v3.3)** | The board is reachable while any downlink frame arrived within 90 s (six missed board HEARTBEATs). Mesh up but board silent → stays in "finding the network" (white breathe) and TEST runs the survey instead of a walk test | Implemented (2026-09-27) |

### 4.5 Alarm handling and operator actions

| Ref | Function | Node's part | Status |
|---|---|---|---|
| 5.1 | Alarm latching | Device-side: stays in alarm, keeps re-announcing until `RESET`; the panel latch is the board's / tablet's | POC (device side) |
| 5.2 | SILENCE / RESET | `SILENCE` stops the sounder, keeps the alarm; `RESET` leaves alarm state if the condition cleared and stops re-announcing | POC |
| 5.3 | **Test button** | Short press = `MANUAL_TEST` ALERT with ACK required (walk test); double tap = bench ALARM; hold 5 s = factory reset; while there is no path to the board the same press is the survey | Phase 1 firmware |
| 5.4 | IDENTIFY | Blink blue for N seconds on `COMMAND IDENTIFY` | POC |
| 5.5 | Smoke / heat detection | ADPD188BI + HDC2080 with pre-alarm trend, raw values reported | Planned (sensing phase) |
| 5.6 | Sirens | Sounds on `COMMAND SOUND` **and on any authenticated ALARM it overhears**, board reachable or not | Planned (`SOUND` undefined) |
| 5.7 | Relay output | `RELAY_SET` → GPIO 12 | Planned |
| 5.8 | Power and tamper | AC lost / on battery / charging / tamper troubles from GPIO 5 / 6 / 7 / 11 | Planned (only `AC_OK` read today) |

### 4.6 Maintenance and updates

| Ref | Function | Node's part | Status |
|---|---|---|---|
| 7.1 | Rename / retire / replace / forget | `SET_DEVICE` and `DECOMMISSION` reach the node; retire / unretire / replace / forget are board-side only. A retired node that still holds the code can still join the Wi-Fi mesh; the board just drops its frames — true exclusion is decommission or re-key | Implemented (bench pending) |
| 7.3 | Channel change | Learns `SET_CHANNEL {channel, switch_at}` from downlink; switches at `switch_at` | Planned (undefined) |
| 7.4 | OTA | Pulls `/fw/node.bin` from the board over plain HTTP (through its parent's NAPT at depth ≥ 2), writes the inactive slot, self-tests, `esp_ota_mark_app_valid_cancel_rollback()` or rolls back; one node at a time, root last | Planned, not scheduled |
| 7.7 | LED language | See §5 | Phase 1 firmware |

## 5. States, modes and LED language

Node top-level states (brief §3, owned by `siot_netcore`, published on the event bus):

```
SETUP → JOINING (level 0) → ONLINE (level ≥ 1; root additionally has the TCP socket up)
      → DEGRADED (root with the board socket down, or a critical EVENT that exhausted its 3 fast
                  retries → local TROUBLE COMM_FAULT)
      → OFFLINE (Mesh-Lite dropped to level 0)
plus FACTORY_RESET (button ≥ 5 s) and UNPROVISIONED_FACTORY (no identity)
```

| State / role | LED | Notes |
|---|---|---|
| Setup (no code) | **white blink** | `SIOT-SETUP-<id>` up, waiting for the phone |
| Finding the network / no path to the board | **white breathe** (slow dim fade) — the POC bench still shows white solid | Provisioned, joining, or mesh up with the board silent > 90 s; TEST = survey; "dark = locked, breathing = press" |
| Root (level 1, board session up) | **green flash 250 ms every 5 s** | |
| Child node (level ≥ 2) | **off** | Console prints a `THIS DEVICE IS A NODE` banner |
| Survey, passive unit | 1 s solid green / yellow / red | ≥ −75 / ≥ −85 / below dBm at which it heard the probe |
| Survey, pressed unit | dark 4.5 s, one 400 ms blink per answering unit in that link's colour; one red blink = nobody | Button locked while dark |
| IDENTIFY | blue blink, 1 s period, N s | Suppresses traffic pulses meanwhile |
| Alarm latched | red solid | Until `RESET` |
| Factory-reset armed | white solid ≥ 5 s | Then reboot into setup |
| Unprovisioned factory | red slow | No `id` / `pop` |

Traffic pulses (ref 7.7; only when this node transmits, never on receive): **blue 100 ms** = background frame
(`HEARTBEAT`, `TOPOLOGY`, `NAME_ANNOUNCE`); **blue 500 ms** = message (`EVENT`, `ACK`); **cyan 500 ms** = the
tablet's ACK for a frame this node sent arrived (the only cyan). A walk-test tap reads **blue then cyan**;
three blues 2 s apart and no cyan = no ACK (tablet not connected or link down).

## 6. Messages — what a node originates, answers and relays

| Direction | Message | Node behaviour |
|---|---|---|
| Up (own) | `HEARTBEAT` 0x02 / 15 s, `TOPOLOGY` 0x03 / 60 s + child change | Never `F_ACK_REQ`; `TOPOLOGY` `NODE_ROLE` 0 root / 1 node |
| Up (own) | `NAME_ANNOUNCE` 0x0A | Once after joining with a path to the board; again after `SET_DEVICE`; trailing role byte |
| Up (own) | `EVENT` 0x01 | `MANUAL_TEST` ALERT (tap), ALARM (double tap on the bench; sensors later), `COMM_FAULT` / `RESTORE` on state changes; ALARM / TROUBLE with `F_ACK_REQ` + fast retry + 60 s re-announce |
| Up (own) | `ACK` 0x04 | For every `COMMAND` addressed to it (`IDENTIFY`, `TEST`, `RESET`, `SILENCE`, `SET_DEVICE`, `DECOMMISSION`…); `LINK_CHECK` is ACKed by the root on behalf of the mesh |
| Up (relay, root and relays) | Everything from the subtree | Copied without decrypting; root → board over TCP |
| Down (relay) | `COMMAND`, `TIME_SYNC`, board `HEARTBEAT`, tablet `ACK` | Re-broadcast one hop, dedupe by MSG_ID; act only if `DST_MAC` = own or broadcast |
| ESP-NOW | `PARENT_PROBE` 0x0D (prober) / `PARENT_OFFER` 0x0E (answerer) | Survey today (`purpose = 1`); leaf parent discovery in Phase 2 (`purpose = 0`, only when ONLINE). Through `esp_mesh_lite_espnow_*` with data-type byte `0xD2` because Mesh-Lite owns `esp_now_init` |

## 7. Storage

| Where | What | Written |
|---|---|---|
| `nvs_factory` / `siot_fact` | `id`, `pop` | Factory station only |
| `nvs` / `siot_inst` | `code` blob (`system_id`, `net_ssid`, `net_psk`, `safr_psk[16]`, `channel`, `mesh_id`, `name[33]`, `zone[17]`), `boot_ctr`, `dev_seq` | Provisioning, `SET_DEVICE`; erased by factory reset / `DECOMMISSION`. Phase 2 adds `role`, `parent_mac` |
| `journal` partition (planned, 256 KB) | Outage storage: state changes and alarms, ≈ 40 B per record | Never heartbeats |
| RAM, bounded | Retry queue, downlink dedupe window, per-leaf mailbox (Phase 2, ≈ 128 B per leaf) | |

## 8. Numbers

| Quantity | Value | Source |
|---|---|---|
| HEARTBEAT / TOPOLOGY / NAME_ANNOUNCE | 15 s / 60 s / once after join | spec §9.2, brief §9 |
| Missing at the board | 45 s (3 missed heartbeats); limits 200 s NFPA 72 / 300 s EN 54-25 | spec §9.2 |
| Board silence, node side | 90 s = 6 missed board HEARTBEATs | spec §9.3 v3.3 |
| Fast retry | 3 × at 2 s, then `COMM_FAULT` | spec §7.2 |
| Alarm re-announce | every 60 s until `RESET` | spec §7.2 |
| Alarm to panel | budget ≤ 10 s end to end; measured ≪ 1 s on a 2-level mesh | ref §4 |
| Root failover | target < 60 s, max 120 s; POC code: 25 s beacon timeout, ~60 s blocking connect, ~11 s keepalive — **5× series not yet run** | ref 2.3, brief §14 item 5 |
| Mesh depth | up to 4 levels; `CHILD_COUNT` ≤ 16 in `TOPOLOGY` | blueprint §4, spec §7.4 |
| ESP-NOW peers (Phase 2) | 20 total, 6 encrypted — a parent adds a leaf as an unencrypted peer on wake, answers, drops it; SAFR does the encryption | ref §4.1 item 4 (`esp_now.h`, IDF 5.5.2) |
| Survey probe | 4 copies 1.2 s apart; window 4.5 s; green ≥ −75 dBm, yellow ≥ −85 dBm | lifecycle §6 |
| Root heap pass mark | min free heap above ~100 KB under 250-device load with an OTA in flight | ref §4.1 |
| Cold start to all-green | about 2 min for 50 units | blueprint §4 |

## 9. What is still missing on a node

1. Persisted `BOOT_CTR` / `DEV_SEQ`, replay check, ALARM-first queue, bounded queues audit (Phase 1 step 4).
2. Board-side items the node depends on: synthetic missing TROUBLE, board clock.
3. The 5× failover series, 24 h soak, `hil/phase1.py` (Phase 1 step 5; ref 2.3 numbers).
4. The `journal` partition in the first fielded table; `CONFIG_SPIRAM_IGNORE_NOTFOUND` build (ref §4.1).
5. Heap fields in `TOPOLOGY`; the root-heap load-mode test that closes the N4 purchase (ref §4.1).
6. Phase 2 parent role: `PARENT_OFFER purpose = 0`, leaf HEARTBEAT ACK with `PENDING`, mailbox, store-and-forward (ref 2.7; brief §6.4, §14 item 15).
7. Sensing, sirens / `COMMAND SOUND`, relay, power / tamper troubles (ref 5.5–5.8).
8. `SET_CHANNEL`, OTA pull, factory identity station (ref 7.3–7.5).
9. `siot_console` (brief §11); bench passes 3, 4, 6–8, 10 of the lifecycle brief.

## 10. Where it lives

- App: `firmware/apps/node` (`app_main.c`, `sdkconfig.defaults`, `partitions_node.csv`; pulls `espressif/mesh_lite 1.0.2`
  into `managed_components/`, pinned by `dependencies.lock`; the `patch does not apply` lines on every build are pre-existing and harmless).
- Components: `siot_netcore` (states, emitter, fast retry, re-announce, downlink, board-silence, announce-on-proven-path),
  `siot_link` (`link_mesh_node.c` Mesh-Lite + root TCP client), `siot_survey`, `siot_provisioning`, `siot_safr`, `siot_config`,
  `siot_identity`, `siot_ui_led`, `siot_ui_button`.
- Build / flash: `firmware/build.sh node`, `tools/flash.sh node <port> [--erase]`.
- Reference implementation (read-only): `pocs/node`, `pocs/patinha` (GPIO / LED / button), `mocked-device/`.
- Specs: reference §2, §3, §4.1; blueprint §0, §1, §4, §5.2, §6, §7; lifecycle §3.2, §5, §6, §9; protocol §1, §7.1–§7.5,
  §7.11, §7.14–§7.15, §9; Phase 1 brief §3, §4, §6.3, §6.4, §9, §14; OTA blueprint §1.1, §1.4, §3.4;
  PCB map `docs/spec/definition-detector.md`.
