# SempreIoT — Leaf (battery detector)

_2026-09-28. One page per device type, compiled from `docs/sempreiot-system-reference.md` (rows quoted as
"ref 2.7" etc.), the blueprint, the lifecycle spec, the protocol and the Phase 1 brief. When this page and
the reference disagree, the reference wins; fix this page. Sibling pages: `board.md`, `node.md`._

**Status in one line:** the leaf is **specified, not built**. Its link is protocol **§12 (v3.4,
2026-09-28)**: wake cycle, binding, the 9-byte parent ACK, mailbox, custody + outbox, alarm fallback,
button verdict, 2-minute setup window. The plan is `docs/phases-development/phase2-leaf-brief.md`. No
firmware exists yet (`apps/leaf` is reserved).

---

## 1. Definition

A **battery detector** is a smoke / heat detector powered from batteries. It sleeps, wakes on a timer or
on a sensor interrupt, talks by **ESP-NOW to one AC device** (its *parent*), and sleeps again. In the
protocol and the firmware it is the **leaf** (ref §2, blueprint §0, spec §1).

What a leaf is **not** (blueprint §0, rule 3; spec §1):

- **Never root, never relay.** It accepts no connections and forwards nothing.
- **Never associates to Wi-Fi after provisioning.** ESP-NOW only, station interface, fixed channel from the
  code, no scanning (the one exception is the OTA pull, OTA blueprint §3.5, battery ≥ 60 %).
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
3. **A leaf in alarm must not sleep** — it stays awake until the **board's** end-to-end ACK, keeps its radio
   up, re-announces every 60 s until restore or `RESET`, and falls back to an ESP-NOW broadcast when the
   unicast to its parent fails (spec §7.2 item 3, §12.6).
3b. **No LED in sleep, ever.** Patterns only in the setup window, the post-provisioning verdict, a button
   press and the COMM_FAULT chirp (spec §12.2, §12.8).
4. Discovery is transport-agnostic: a leaf's frames reach the board through its parent and populate the
   device table like any other (lifecycle §5.2).
5. A leaf sends `NAME_ANNOUNCE` **once after provisioning**, not on every wake (a wake is a reboot); the
   "announced" flag lives in RTC memory (spec §7.11, lifecycle §5.2).
6. Setup network until **2 minutes pass without a provisioning request or a phone joining**, and at most
   **10 minutes after boot**; then deep sleep with the button as the only wake source; a short press re-arms
   it (spec §12.9, blueprint §2). A phone that merely stays associated never keeps a leaf awake.
7. Siting rule: each detector should have ≥ 2 AC devices in reach (blueprint §7); the tablet flags any
   detector that had fewer than two `PARENT_OFFER`s in the walk test (blueprint §6.4).

## 4. Behaviour (protocol §12 — normative; blueprint §5.1, §6 follow it)

**Wake cycle, every 60 s fixed** (spec §12.2): radio on, installation channel → **drain the outbox**
(oldest first, original timestamps and sequence numbers) → `HEARTBEAT` unicast to the bound parent with
`F_ACK_REQ` → wait ≤ 100 ms for the parent's 9-byte ACK → set RTC clock from `EPOCH`, switch channel if
`CHANNEL` differs → if `PENDING`, stay awake and receive `DETAIL` (≤ 4) queued frames, ACK the ones that
ask → sleep. Hard budget 500 ms outside alarm. State lives in RTC memory; a wake is a reboot. Wake sources:
timer, sensor (GPIO 4), button (GPIO 21).

**Binding** (spec §12.3): `PARENT_PROBE {0}` broadcast, listen ≈ 200 ms; every AC device offers, ONLINE ones with their layer, the others with `0xFF` (heard, never bound; the board never offers).
Link = weaker of the two directions. Best link wins, lower layer breaks ties, prefer ≥ −85 dBm but bind to
the best available anyway. After a bind: `NAME_ANNOUNCE` (once ever), `TOPOLOGY` with the parent
candidates, `HEARTBEAT`. Re-probe on the 2nd consecutive miss (≈ 120 s, before the board's 180 s rule),
on the next wake after `NO_PATH`, and once a day. Unbound back-off: every wake while nodes are heard but
none online (board not there yet), every 5 min when nobody answers.

**Losing the parent** (spec §12.3, §12.6): miss → miss → probe → new parent. Nobody: COMM_FAULT, one red
blink + trouble chirp per wake, events go to the outbox, the board shows the leaf missing at 180 s.
Parent up but board gone: the ACK says `NO_PATH`; the leaf keeps the parent (it is still the best relay),
probes next wake, and its events sit in the parent's custody until the board is back.

**Events — three tiers** (spec §12.6): every leaf `EVENT` carries `F_ACK_REQ`. (1) The parent ACKs on the
same wake = **custody**: it retries upward until the board ACKs; the leaf sleeps. (2) **ALARM** is end to
end: the leaf stays awake until the board's ACK (`SRC_MAC` = board), re-announces every 60 s, sounds
locally. (3) Unicast ALARM fails at the MAC → **broadcast** the same frame at once; every node that hears
it forwards it, the board dedupes by `DEV_SEQ`. **Outbox** for events with no parent at all: 16 entries
≈ 40 B, RTC memory mirrored to NVS on every write, never heartbeats, drained before the next heartbeat.
An alarm that clears before any ACK is stored as ALARM + RESTORE so the panel still learns of it.

**Downlink** (spec §12.5): nothing is pushed to a sleeping leaf. The parent's **mailbox** holds ≤ 4
frames per leaf (`SET_DEVICE`, `DECOMMISSION`, `RESET`, `SILENCE`, `IDENTIFY`, `TEST`, `RELAY_SET`, later
the OTA offer; never `TIME_SYNC`), flags them in the heartbeat ACK, sends them right after, expires them
after 180 s or when the leaf reappears through another parent. The board's device table is the truth: on
the leaf's first frame through any parent it re-originates every pending command.

**Button** (spec §12.8): the single GPIO 21 button wakes the leaf and **always transmits**. Immediate blue
100 ms → unbound: one discovery first (one blink per answering unit) → bound with a path: `MANUAL_TEST`
(blue sent, **cyan** = the panel's ACK came back within ≈ 3 s, else one red blink) → otherwise: survey
probe (one blink per answering unit in its colour, one red = nobody) → sleep. Probe copies never pulse blue. Hold 5 s = factory reset. Double tap = bench ALARM. Survey is run *from* a leaf, never
*to* it.

**After provisioning** (spec §12.8, §12.9): `stored` → awake ≤ 30 s: probe → bind → announce → one blink
per candidate → **green solid 3 s** (bound and acknowledged, no `NO_PATH`) or **one red blink** → sleep.
Setup network 2 minutes; no `/identify` → deep sleep, button-only wake.

**Supervision** (spec §9.2): the board marks a leaf missing after 3 × 60 s = 180 s, inside the 200 s
NFPA 72 / 300 s EN 54-25 limits.

**Lifecycle** (lifecycle §5.2): retire, replace and forget are immediate (board-side); rename and
decommission ride the mailbox, applied on the next wake.

**OTA** (OTA blueprint §3.5): on a wake the parent's reply may carry `fw_available`; if battery ≥ 60 %
the leaf joins the mesh Wi-Fi as a station, pulls `/fw/node.bin`, verifies, reboots, self-tests, reports
`OTA_RESULT` and sleeps; ~40–90 s awake once per release; backoff on failure. The offer itself is not yet
on the wire (it will be appended to the leaf ACK, versioned by length — spec §12.4).

## 5. Functionality rows that name the leaf

| Ref | Function | Leaf's part | Status |
|---|---|---|---|
| 1.1–1.4 | Identity, code, setup network, provisioning | Same as every unit; setup network 2 min then button-only sleep | POC (shared code) · leaf image Planned |
| 1.9 | Naming | `NAME_ANNOUNCE` once after provisioning with `ROLE 2`; later names through the mailbox | Specified (spec §12.9) |
| 1.10 | Survey | Prober only; press always transmits; no dark period | Specified (spec §12.8) |
| 2.7 | **ESP-NOW battery link** | Wake cycle, 9-byte ACK, binding, back-off | **Specified (spec §12)** · Planned Phase 2 firmware |
| 3.3, 3.4 | ACKed delivery, re-announce | Custody / end-to-end alarm / broadcast fallback / outbox | Specified (spec §12.6) |
| 3.8 | Time sync | `EPOCH` in every parent ACK; never `TIME_SYNC` | Specified (spec §12.4) |
| 4.1 | Heartbeats / topology | `HEARTBEAT` 60 s on wake; one `TOPOLOGY` per bind with parent candidates | Specified (spec §12.7) |
| 4.2 | Missing | 180 s | Board table supports role 2 today |
| 5.3 | Test button | Walk test or survey, decided by state, always sends | Specified (spec §12.8) |
| 5.5 | Smoke / heat detection | ADPD188BI + HDC2080, pre-alarm trend, raw values reported | Planned (sensing phase) |
| 5.8 | Battery and tamper | `BATT_LOW` at ≥ 7 days remaining (NFPA), ~30 days target (EN 54-25); `BATT_CRITICAL`; `TAMPER` | Planned Phase 2+ |
| 7.1 | Rename / decommission | Via mailbox, next wake; retire / replace / forget immediate | Specified (spec §12.5) |
| 7.3 | Channel change | `CHANNEL` in every parent ACK | Specified (spec §12.4) |
| 7.4 | OTA | Pull on wake when the parent says an image is available | Planned, not scheduled |

## 6. Messages — what the leaf sends and receives

| Direction | Message | Leaf behaviour |
|---|---|---|
| Up (own) | `HEARTBEAT` 0x02, every wake, unicast to the parent, `F_ACK_REQ` | The only frame of a quiet wake |
| Up (own) | `EVENT` 0x01, `F_ACK_REQ` always | `MANUAL_TEST`, ALARM (awake until the board's ACK; broadcast on MAC failure), `TROUBLE` / `RESTORE` (custody); outbox replay with original `DEV_SEQ` / `TIMESTAMP` |
| Up (own) | `NAME_ANNOUNCE` 0x0A, `ROLE 2` | Once ever after provisioning; again after an applied `SET_DEVICE` |
| Up (own) | `TOPOLOGY` 0x03, `NODE_ROLE 2` | Once per bind: parent + candidate parents with link RSSI |
| Up (own) | `ACK` 0x04 | For each mailbox frame with `F_ACK_REQ` |
| ESP-NOW | `PARENT_PROBE` 0x0D (`0` discovery, `1` survey) | Discovery on bind / re-probe; survey on a press without a path |
| Down | Leaf `ACK` 0x04, 9 bytes, from the parent | `PENDING` + count, `NO_PATH`, `EPOCH`, `CHANNEL`; `SRC_MAC` = parent (custody) or board (end-to-end) or central (walk-test cyan) |
| Down | `PARENT_OFFER` 0x0E | From ONLINE nodes and the board (`LAYER 0`) |
| Down | Mailbox frames: `COMMAND` (`SET_DEVICE`, `DECOMMISSION`, `RESET`, `SILENCE`, `IDENTIFY`, `TEST`, `RELAY_SET`), central `ACK` | After a `PENDING` ACK, ≤ 4 per wake |

**Not on the wire yet:** the OTA offer in the leaf ACK and `OTA_RESULT`; `COMMAND SOUND` (sirens, not
leafs). Firmware seams already left: `link_kind_t` / `link_register()` accept `LINK_ESPNOW`; `siot_netcore`
and `siot_coordinator` forward any authenticated frame regardless of link (brief §6.4).

## 7. LED language (spec §12.8; blueprint §2 — colours not final)

| State | LED |
|---|---|
| Asleep | **off, always** |
| Setup (no code, 2 min window) | white blink |
| Post-provisioning verdict (≤ 30 s) | one blink per candidate parent in its colour → green solid 3 s (bound) or one red blink |
| Button press | blue 100 ms at once → walk test: blue 500 ms sent, cyan 500 ms confirmed, or one red · survey: one blink per answering unit, one red = nobody |
| COMM_FAULT | one red blink + trouble chirp per wake |
| Alarm active | red solid + local sounder, awake |
| IDENTIFY (from the mailbox) | blue blink N s, then sleep |
| Factory-reset armed | white solid ≥ 5 s |

## 8. Numbers (spec §12.10)

| Quantity | Value |
|---|---|
| Heartbeat interval | 60 s fixed (3 × 60 = 180 s missing; NFPA 72 200 s cap → interval ≤ ≈ 66 s) |
| Wake budget / ACK wait / probe listen | 500 ms / 100 ms / ≈ 200 ms |
| Post-provisioning verdict | ≤ 30 s awake |
| Bind preference / weak-link flag | link ≥ −85 dBm / < −85 flagged, < −75 reported |
| Re-probe | 2nd miss · after `NO_PATH` · every 24 h |
| Unbound back-off | every wake (nodes heard) · every 5 min (nobody) |
| Mailbox | 4 per leaf, same-`CMD` replace, ≤ 4 drained per wake, expiry 180 s |
| Custody queue (parent) | 32 frames, ALARM never dropped |
| Outbox | 16 entries ≈ 40 B, NVS-mirrored |
| Alarm | 3 × 2 s retries, broadcast on MAC failure, re-announce 60 s, awake until the board's ACK |
| Walk-test cyan timeout | ≈ 3 s |
| Setup window | 2 min, then button-only sleep |
| ESP-NOW peers per parent | 20 total, 6 encrypted, add-answer-drop |
| Battery | `BATT_LOW` ≥ 7 days remaining (NFPA), ~30 days (EN); OTA ≥ 60 % |
| Battery life | ≈ 7 months on 2 500 mAh at 60 s (rough); standards ≥ 1 year (NFPA 72) / ≥ 3 years (EN 54-25) to verify — POC D |

## 8b. On the tablet — how a sleeping or lost leaf is shown (decided 2026-09-28)

The tablet already knows three leaf states; §12 fixes their timing and adds two facts. Status words are
the app's (`topology_provider.dart`, `topology_screen.dart`); "Implemented" = in the app today.

| Tablet state | Rule | Map | Node sheet "Estado" | Status |
|---|---|---|---|---|
| **Acordado** | a frame arrived < 3 s ago, or an alarm is latched and not yet RESET (a leaf in alarm is awake, spec §12.6) | green, sensor icon, glow | "Acordado" / "Acordado — em alarme" | Implemented 2026-09-28 |
| **Dormindo** | online (a frame within 180 s) and not awake — the normal state of a healthy leaf, ≈ 99 % of the time | grey, moon icon with a small drifting "z z" inside the circle, no glow; its link keeps the last dBm but in the sleep colour (reference §3.6.2) | "Dormindo · último despertar há 37 s · próximo em ~23 s" (60 s cadence, spec §12.2) | Implemented 2026-09-28 |
| **Sem comunicação** (lost) | silent > 180 s (3 × 60 s), or the board's DEVICE_TABLE says `missing` — whichever comes first | red, dimmed after 10 min | "Sem comunicação há 4 min" + the synthetic TROUBLE "dispositivo ausente" in the feed; any frame restores it | Implemented (180 s, board table authoritative; "há X" 2026-09-28) |
| **Sem comunicação há muito tempo** | silent > 10 min | drawn at 32 % opacity, never auto-removed | same | Implemented |
| **Esperado** | in the board's table from an `/enroll` hint or a rename, never heard | outline only | "Nunca ouvido pela placa" | Implemented (`boardState expected`) |
| **Aposentado** | retired on the board | badge; "aposentado, mas transmitindo" if still heard | | Implemented |

Facts on the leaf's sheet, in addition to name, zone, MAC, RSSI to parent, battery (from HEARTBEAT):

- **Pai:** the bound parent's name (`PARENT_MAC` of the last HEARTBEAT / TOPOLOGY); the map draws the leaf under it. Implemented.
- **Pais ao alcance:** from the bind-time TOPOLOGY (spec §12.7): "2 (−71 / −83 dBm)". **Warning badge** when fewer than 2 or the bound link is below −85 dBm: "só um pai ao alcance — instale um dispositivo AC mais perto" / "sinal fraco com o pai". Same flags in the walk-test report. **Implemented 2026-09-28** (`parentCandidates` column, Drift v9, catalogue §3.6.1); the PDF report itself is still Planned (ref 5.9).
- **Pendências:** "pendente: aplica quando o detector acordar" for rename / decommission (board flags, Implemented) and for any command sent to a sleeping leaf (IDENTIFY, SILENCE, TEST, RESET): the board ACKs the tablet at once, the parent's mailbox delivers on the next wake (spec §12.5). The sheet's note already says so; Implemented.
- **Contadores da Rede:** ATIVOS (awake) / DORMINDO / OFFLINE — Implemented; a leaf that is merely asleep must never count as OFFLINE, and never does.
- **Pacote em trânsito:** every frame a leaf sends is drawn as a small packet travelling leaf → parent → … → central along the tree (accent colour for a heartbeat, the severity colour for an event). AC nodes only animate events, since their heartbeats come every 15 s. Implemented 2026-09-28.

What the tablet cannot show and does not pretend to: a leaf that is unbound or in COMM_FAULT is only visible as **Sem comunicação** after 180 s (the leaf cannot reach the panel to say more); the leaf's outbox contents (delivered events appear with their original timestamps when it reconnects); the leaf's own LED verdicts. A leaf that never got provisioned or slept after its 2-minute setup window is not in the table and not on the map.

## 9. Open items before a leaf can be built

1. POC D: battery pack, measured wake cost, life against the standards (spec §12.12).
2. Chip decision for deep-sleep boot time (brief §14 item 17); every POC assumes `esp32s3`.
3. Peer-to-peer leaf behaviour with no AC device on site (blueprint §11).
4. Sensing thresholds for ADPD188BI / HDC2080 and lab verification of raw values (ref 5.5).
5. The OTA offer fields in the leaf ACK and `OTA_RESULT` (OTA phase).
6. `apps/leaf` image and the parent role under `features/` on the node (brief §13: new components, no
   edits to frozen Phase 1 files) — steps in `phase2-leaf-brief.md`.

## 10. Where it lives

- Firmware (2026-09-28, bench pending): `firmware/apps/leaf` (no Mesh-Lite), `components/core/siot_leaf_proto`
  (host-tested protocol pieces), `components/net/siot_leafcore` (runtime), `components/platform/siot_sensor`
  (mock). The parent role on the node is not built yet (brief step 3). Plan: `docs/phases-development/phase2-leaf-brief.md`.
- Shared today: `siot_survey` (probe / offer), `siot_devtab` and the tablet's `MeshDevices` (role 2, 180 s rule),
  `siot_provisioning`.
- Specs: **protocol §12** (normative), §3.2, §7.3–§7.5, §7.11, §7.14, §7.15, §9.2, §11; reference §2, §3.2 row 2.7,
  §4, §4.1; blueprint §0, §1 rules 3 and 10, §2, §4, §5.1, §5.2, §6, §7, §11; lifecycle §5.2, §6; Phase 1 brief
  §6.4, §14 items 15–18; OTA blueprint §1.4, §3.5; PCB map `docs/spec/definition-detector.md`.
