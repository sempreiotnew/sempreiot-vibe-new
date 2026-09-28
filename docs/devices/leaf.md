# SempreIoT — Leaf (battery detector)

_2026-09-28. One page per device type, compiled from `docs/sempreiot-system-reference.md` (rows quoted as
"ref 2.7" etc.), the blueprint, the lifecycle spec, the protocol and the Phase 1 brief. When this page and
the reference disagree, the reference wins; fix this page. Sibling pages: `board.md`, `node.md`._

**Status in one line:** the leaf is **Planned Phase 2**. Its behaviour is decided (blueprint), two of its
messages are on the wire (`PARENT_PROBE`, `PARENT_OFFER`), and nothing else is specified or coded. This
page states what is decided, what is written, and what is still open, and does not invent the rest.

---

## 1. Definition

A **battery detector** is a smoke / heat detector powered from batteries. It sleeps, wakes on a timer or
on a sensor interrupt, talks by **ESP-NOW to one AC device** (its *parent*), and sleeps again. In the
protocol and the firmware it is the **leaf** (ref §2, blueprint §0, spec §1).

What a leaf is **not** (blueprint §0, rule 3; spec §1):

- **Never root, never relay.** It accepts no connections and forwards nothing.
- **Never associates to Wi-Fi after provisioning.** ESP-NOW only (the one exception is the planned OTA
  pull, OTA blueprint §3.5).
- **Never ACKs** in the spec's system model; it is the passive end of every exchange.
- Not a mesh node: Mesh-Lite runs only on AC devices. A site with no AC device has no mesh; leafs work
  standalone (local alarm) until one appears (rule 10). Whether leafs interlink peer-to-peer with no AC
  device present is still open (blueprint §11).

## 2. Hardware

| Item | Value | Source |
|---|---|---|
| Module | **ESP32-S3-WROOM-1-N4** — 4 MB flash, no PSRAM; PSRAM would cost standby current for nothing | ref §2, §4.1 |
| Power | Batteries; battery pack and target life to be decided by POC D — **not yet measured** | ref §4, blueprint §11 |
| Sensors | **ADPD188BI** smoke (I2C, blue + IR LEDs, heater) + **HDC2080** temperature / humidity; both wake the ESP on GPIO 4 (`DTR_SLEEP`) | ref §2, `docs/spec/definition-detector.md` |
| Inputs | ACOK 5, BOOST 6, CHG 7 (battery state), TAMPER 11 (removed from base), RST/TESTE 21, BATT ADC 10, NTC ADC 9 | `definition-detector.md`, spec §7.1.3 |
| Outputs | RGB LED 14 / 47 / 48; relay 12; I2C level-shifter enable 38 | `definition-detector.md` |
| Flash layout | Same 4 MB table as the node (`ota_0` / `ota_1` 1.875 MB, `nvs_factory`, `coredump`); same journal-partition rule | OTA blueprint §1.1, §1.4 |
| Firmware image | `apps/leaf` — Phase 2; does not exist yet | `firmware/README.md` |
| Chip decision | Classic ESP32-WROOM vs S3 is still listed as open for deep-sleep boot time; every POC assumes `esp32s3` | brief §14 item 17 |

## 3. Rules that bind a leaf

1. ESP-NOW only after provisioning (blueprint rule 3).
2. SAFR v3 end-to-end: every ESP-NOW frame is a normal authenticated SAFR frame, `LEN ≤ 250` so it is
   ESP-NOW-legal; the parent relays it up without decrypting (rule 7; brief §6.4).
3. **A leaf in alarm must not sleep** — it stays awake, keeps its radio up and re-announces every 60 s until
   restore or `RESET` (spec §7.2 item 3).
4. Discovery is transport-agnostic: a leaf's frames reach the board through its parent and populate the
   device table like any other (lifecycle §5.2).
5. A leaf sends `NAME_ANNOUNCE` **once after provisioning**, not on every wake (a wake is a reboot); the
   "announced" flag lives in RTC memory (spec §7.11, lifecycle §5.2).
6. Provisioning is unchanged: setup network for 10 minutes, re-armed by a button press (blueprint §2).
7. Siting rule: each detector should have ≥ 2 AC devices in reach (blueprint §7); the tablet flags any
   detector that had fewer than two `PARENT_OFFER`s in the walk test (blueprint §6.4).

## 4. Decided behaviour (blueprint §4 item 5, §5.1, §6)

**Wake cycle, every 60 s (configurable 60–150 s):** wake → radio on, installation channel → ESP-NOW
`HEARTBEAT` to the bound parent → wait ≤ 100 ms for the parent's ACK → if the ACK carries the **PENDING**
flag, stay awake and fetch the queued command → sleep. Wake budget target ≤ 500 ms. The smoke sensor
samples autonomously and wakes the ESP by GPIO 4 on threshold.

**Parent binding:** with no bound parent, or after 3 consecutive heartbeats without an ACK, broadcast
`PARENT_PROBE {purpose = 0}`; every ONLINE AC device in reach answers `PARENT_OFFER {rssi_seen, layer}`; bind
to the best (prefer a shallow parent), store the MAC in RTC memory. Nobody answers → local `COMM_FAULT`
(red LED, trouble chirp) and keep trying at the normal cadence.

**Alarm:** sense → wake → `EVENT ALARM` with `F_ACK_REQ` to the parent → stay awake. The parent stores and
forwards up the mesh with SAFR retries until the board ACKs end to end. No ACK within 2 s → 3 retries →
`PARENT_PROBE` + re-bind → keep going. Every 60 s re-announce the same ALARM (`F_RETX`, same `DEV_SEQ`)
until `RESET`.

**Supervision:** the board marks a leaf missing after 3 × its heartbeat interval (180 s at 60 s), inside
the 200 s NFPA 72 / 300 s EN 54-25 limits (spec §9.2, ref §4).

**Lifecycle (lifecycle §5.2):** retire, replace and forget are immediate (board-side). Rename and
decommission are **never immediate**: they ride the parent mailbox + ACK `PENDING` bit. Until the mailbox
exists the board keeps `PENDING_RENAME` / `PENDING_DECOMMISSION`, the tablet shows "pendente: aplica quando
o detector acordar", and remote wipe is best effort — retire plus the physical 5 s hold is the reliable path.

**Survey (lifecycle §6):** a provisioned leaf with no path to the board runs the same range survey as a node
on its TEST button; an awake leaf also answers other units' survey probes.

**OTA (OTA blueprint §3.5):** on a wake the parent's reply may carry `fw_available`; if battery ≥ 60 % the
leaf joins the mesh Wi-Fi as a station, pulls `/fw/node.bin` from the board (through NAPT if via a parent),
verifies, reboots, self-tests, reports `OTA_RESULT` and sleeps; ~40–90 s awake once per release; retries
with backoff (next wake, then every 6 h, max 5).

## 5. Functionality rows that name the leaf

| Ref | Function | Leaf's part | Status |
|---|---|---|---|
| 1.1–1.4 | Identity, code, setup network, provisioning | Same as every unit; the setup network stops after 10 min and re-arms on a button press | POC (shared code) · leaf image Planned |
| 1.9 | Naming | `NAME_ANNOUNCE` once after provisioning; names otherwise from hints or `SET_DEVICE` via the mailbox | Planned Phase 2 |
| 1.10 | Survey | Prober or awake responder, same rules as a node | Message pair Implemented on nodes; leaf image Planned |
| 2.7 | **ESP-NOW battery link** | Wake → `HEARTBEAT` to the bound parent → ACK (with `PENDING`) → sleep; bind by probe / offer | Planned Phase 2 (wire format not yet written) |
| 3.3, 3.4 | ACKed delivery, re-announce | ALARM / TROUBLE with `F_ACK_REQ`; awake while in alarm; 60 s re-announce | Planned Phase 2 |
| 4.1 | Heartbeats | Every 60 s on wake; no `TOPOLOGY` (`NODE_ROLE 2 leaf` is set by the parent's table) | Planned Phase 2 |
| 4.2 | Missing | 180 s at a 60 s interval | Board table supports the role today; leaf Planned |
| 5.5 | Smoke / heat detection | ADPD188BI + HDC2080, pre-alarm trend, raw values reported | Planned (sensing phase) |
| 5.8 | Battery and tamper | `BATT_LOW` at ≥ 7 days remaining (NFPA), ~30 days target (EN 54-25); `BATT_CRITICAL`; `TAMPER` | Planned Phase 2+ |
| 7.1 | Rename / decommission | Pending via mailbox + `PENDING`; retire / replace / forget immediate | Board side Implemented; leaf Planned |
| 7.4 | OTA | Pull on wake when the parent says an image is available | Planned, not scheduled |

## 6. What is on the wire today, and what is not

**Specified (protocol v3.2):**

| Message | Payload | Use |
|---|---|---|
| `PARENT_PROBE` 0x0D, ESP-NOW broadcast | `PURPOSE` u8: `0` parent discovery · `1` survey | Leaf looking for a parent (0); range test (1) |
| `PARENT_OFFER` 0x0E, ESP-NOW unicast | `PURPOSE`, `RSSI_SEEN` int8, `LAYER` (`0xFF` = not on a mesh, `0x00` = the board) | Only ONLINE AC units answer `purpose = 0`; a leaf prefers a shallow parent |
| `HEARTBEAT` 0x02 | 20 bytes, `BATTERY_PCT`, `PWR_FLAGS` | Existing layout; leaf cadence 60 s |
| `NAME_ANNOUNCE` 0x0A | trailing `ROLE = 2` (battery leaf) | Once after provisioning |
| `TOPOLOGY` `NODE_ROLE 2`, device-table `role 2` | | Board and tablet already carry the leaf role |

**Not specified yet — the first task of Phase 2 (brief §6.4, §14 item 15; ref 2.7):**

- The parent's ACK to a leaf `HEARTBEAT` (the "leaf heartbeat is ACKed" exception to §7.3) and the ACK
  `PENDING` bit (`0x04`).
- The parent mailbox: what is queued, how the leaf fetches it, how long it stays awake.
- `PARENT_OFFER {mac, level, load}` as the blueprint words it vs the 3-byte v3.2 layout — the blueprint's
  `load` field is not on the wire.
- `COMMAND SOUND`, `SET_CHANNEL` (a leaf learns the channel from its next ACK), the OTA `fw_available`
  reply and `OTA_RESULT`.
- Leaf keys in `siot_inst`: `role`, `parent_mac` (brief §4.2).
- Channel pinning with the board absent, and Mesh-Lite + ESP-NOW coexistence on the S3 (brief §14 item 16).
- Firmware seams already left for it: `link_kind_t` / `link_register()` accept a third backend
  (`LINK_ESPNOW`) without signature changes; `siot_netcore` and `siot_coordinator` forward any
  authenticated frame regardless of link; `PWR_FLAGS` bit 0 (`AC_OK`) is read and will drive the role
  switch (brief §6.4).

## 7. LED language (blueprint §2, lifecycle §6 — colours not final)

| State | LED |
|---|---|
| Setup (no code, ≤ 10 min, re-armed by a button press) | white blink |
| Configured, no path to the board | white breathe |
| Installed (first authenticated frame heard by the board) | green solid 3 s |
| Fault / `COMM_FAULT` | red (+ trouble chirp) |
| Test button pressed | blue short blink |
| Survey, passive | 1 s green / yellow / red |
| Survey, pressed | dark ≈ 4.5 s, one blink per answering unit, one red = nobody |
| Factory-reset armed | white solid ≥ 5 s |

## 8. Numbers

| Quantity | Value | Source |
|---|---|---|
| Heartbeat cadence | 60 s, configurable 60–150 s | blueprint §5.1 |
| Wake budget | ≤ 500 ms; ACK wait ≤ 100 ms | blueprint §5.1 |
| Missing at the board | 3 × interval = 180 s at 60 s; limits 200 s / 300 s | spec §9.2 |
| Re-bind trigger | 3 consecutive heartbeats without ACK | blueprint §5.1 |
| Fast retry / re-announce | 3 × at 2 s / every 60 s | spec §7.2 |
| Battery warning | `BATT_LOW` ≥ 7 days remaining (NFPA 72), ~30 days (EN 54-25) | spec §7.1.2 |
| Setup network | 10 min, then off until a button press | blueprint §2 |
| Peers per parent | 20 ESP-NOW peers total, 6 encrypted → add-answer-drop per wake; per-leaf state ≈ 128 B, 250 leafs on one parent = 32 KB | ref §4.1 item 4 |
| Airtime | Hundreds of detectors waking every 60–150 s per parent is the real bound — an installer placement rule | ref §4.1 item 4 |
| OTA pull | battery ≥ 60 %, ~40–90 s awake, once per release | OTA blueprint §3.5 |
| Battery life | Not measured (POC D) | ref §4 |

## 9. Open items before a leaf can be built

1. Write the v3.1 / Phase 2 protocol section (§6 above) — first task of Phase 2.
2. POC D: battery pack, cadence, measured life.
3. Chip decision for deep-sleep boot time (brief §14 item 17).
4. Peer-to-peer leaf behaviour with no AC device on site (blueprint §11).
5. Sensing thresholds for ADPD188BI / HDC2080 and lab verification of raw values (ref 5.5).
6. `apps/leaf` image, `features/` plug-ins for the parent role on nodes (brief §13: new components, new
   `MSG_TYPE`s, no edits to frozen Phase 1 files).

## 10. Where it lives

- Firmware: **nothing yet**. `firmware/apps/leaf` is reserved (`firmware/README.md`); Phase 2 work goes under
  `firmware/components/features/` per `features/README.md`.
- Shared today: `siot_survey` (probe / offer), `siot_devtab` and the tablet's `MeshDevices` (role 2, 180 s rule),
  `siot_provisioning`.
- Specs: reference §2, §3.2 row 2.7, §4, §4.1; blueprint §0, §1 rules 3 and 10, §2, §4, §5.1, §6, §7, §11;
  lifecycle §5.2, §6; protocol §1, §7.1–§7.3, §7.11, §7.14, §7.15, §9.2; Phase 1 brief §6.4, §14 items 15–18;
  OTA blueprint §1.4, §3.5; PCB map `docs/spec/definition-detector.md`.
