# Phase 2 brief — Battery detector (leaf): protocol first, firmware on devkits

_2026-09-28. The plan behind protocol §12 (v3.4) and `docs/devices/leaf.md`. Authority: below the
protocol, the blueprint and the lifecycle spec; this file records decisions, the bench plan and the
checklist, the specs record rules. Written before any leaf firmware exists and before the detector PCB
is available._

---

## 1. Why now, and why the protocol first

The network (board, nodes, tablet) is grounded: Phase 1 steps 1–3 run on the bench, the lifecycle
commands are coded. The next firmware feature is **OTA**, and OTA has a leaf leg (pull on wake, offer in
the parent's ACK). So the leaf's wire behaviour had to be fixed before OTA is designed, even though the
leaf firmware itself is not the next thing built. Protocol §12 is that fix. This brief keeps the
reasoning and the bench plan so the firmware can start whenever the hardware question is answered.

## 2. Decisions (2026-09-28; rules in protocol §12)

1. **ESP-NOW only**, no fallback to joining the mesh. ESP-NOW at 1 Mbps reaches farther than an
   802.11n association, so a fallback would cost 5–10× the energy for a worse link. The OTA pull is
   the one justified association.
2. **Unicast to the bound parent**; the MAC-layer ACK is the hop proof, the SAFR ACK the application
   proof. **Alarm broadcast fallback** on MAC failure — in.
3. **ACK extension** rather than mailbox `TIME_SYNC`: the parent's 9-byte leaf ACK carries `PENDING` +
   count, `NO_PATH`, `EPOCH`, `CHANNEL` — option B, in.
4. **Three stores**: leaf outbox (events with no parent), parent custody queue (events not yet ACKed by
   the board), parent mailbox (downlink for a sleeping leaf). The board's table is the truth behind the
   mailbox.
5. **Every leaf event and heartbeat is ACK-required**; the hop ACK is the permission to sleep; an ALARM
   waits for the board's end-to-end ACK, awake and sounding.
6. **60 s fixed** heartbeat: the 3-miss rule caps the interval at ≈ 66 s under NFPA 72's 200 s; the
   former 60–150 s range is dropped until POC D measures the battery.
7. **Re-probe on the 2nd miss** (≈ 120 s), so a dead parent is replaced before the board's 180 s rule.
8. **Setup window**: 2 minutes without a provisioning request or a phone joining, 10 minutes cap from
   boot, then deep sleep with the button as the only wake source and the radio stopped first. A phone
   merely associated is not activity (found on the bench 2026-09-28: the first cut slept 120 s after
   boot regardless, then a second cut paused while a phone was associated — both wrong). After `stored`
   the leaf gives its verdict on the spot (≤ 30 s): blinks per parent, green 3 s or one red.
9. **No LED in sleep, ever.** A press always transmits and the LED answers immediately; the colour tells
   whether the walk test (cyan) or the survey (coloured blinks) ran. Survey from the leaf, never to it.
10. A leaf sends one **TOPOLOGY per bind** listing its parent candidates — the walk-test report's source.
11. `apps/leaf` is a separate image; the parent role on the node goes under `features/`; no edits to
    frozen Phase 1 files except with a test (brief §13).

## 3. The bench without leaf hardware

Only ESP32-S3 devkits exist; the detector PCB and its sensors do not. What is real and what is mocked:

| Concern | On the devkit | Verified where |
|---|---|---|
| Deep sleep | **Real**, independent of the power source (USB or mains). Timer wake, EXT1 GPIO wake, `esp_deep_sleep_start`, wake-cause query | `esp_sleep.h`, IDF 5.5.2 |
| Wake pins | GPIO 21 (button) and GPIO 4 (sensor) are RTC-capable on the S3 (22 RTC pins, GPIO 0–21) | `soc_caps.h` `SOC_RTCIO_PIN_COUNT 22` |
| State across wakes | `RTC_DATA_ATTR` | `esp_attr.h` |
| ESP-NOW | Send callback reports MAC success / failure; per-peer rate config; RSSI in `rx_ctrl`; 20 / 6 peers | `esp_now.h` |
| Console | The native USB console **drops on every sleep** → log over UART0 through the USB-TTL adapter | — |
| Current | **Cannot be measured over USB.** Bench proxy: `awake_ms` per wake, logged every wake; real current needs a meter (POC D) | — |
| Sensors | `siot_sensor` interface with a **mock backend** (scripted smoke / temperature); the button stands in for the sensor interrupt: short press = `MANUAL_TEST`, double tap = ALARM | — |
| Battery | Mocked `BATTERY_PCT`, settable from the console; ADC on GPIO 10 later | — |
| Parent | A second devkit running the node image with the parent role | — |
| Sleep mode switch | Kconfig `CONFIG_SIOT_LEAF_SLEEP = deep / light / none` so the same state machine runs under a debugger; **deep is the default** and what the bench runs, so the reboot-per-wake design is never faked | — |

## 4. Cadence and battery — the arithmetic behind decision 6

| Interval | Missing at 3× | NFPA 72 ≤ 200 s | EN 54-25 ≤ 300 s |
|---|---|---|---|
| 60 s | 180 s | pass | pass |
| 90 s | 270 s | fail | pass |
| 150 s | 450 s | fail | fail |

Energy, rough: one wake ≈ 300 ms at ≈ 90 mA ≈ 7.5 µAh → 1 440 wakes/day ≈ 11 mAh/day → ≈ 7 months on
2 500 mAh. The standards' minimum battery life for radio devices is, as recalled, ≥ 1 year (NFPA 72)
and ≥ 3 years (EN 54-25) — **verify against the purchased editions before any promise**. If they hold,
the pack size (or a US-only target) is the lever, not the cadence: a 1-miss rule would allow longer
intervals but makes one lost frame a trouble. POC D measures the wake with a meter and closes this.

## 5. Steps (each ends with something you can see)

| Step | What | You see | Status |
|---|---|---|---|
| **0. Spec** | Protocol §12 (v3.4); blueprint §2 / §5.1 / §5.2 / §6 / §9.2 / §11; lifecycle §5.2 / §6; reference rows 1.10, 2.7, 3.3, 3.8, 4.1, 5.3, §4, §6, index; `docs/devices/{leaf,node,board}.md`; installation guide §3 / §5 / §12 | Docs agree with each other | **Done 2026-09-28** |
| 1. Host tests | Linux-target tests for the 9-byte leaf ACK (both lengths accepted), STATUS flags, parent selection, outbox ring, probe / budget policy — `components/core/siot_leaf_proto` | `firmware/build.sh host` green (40 tests, 7 leaf) | **Done 2026-09-28** |
| 2. `apps/leaf` skeleton | Deep-sleep boot, RTC state, wake-cause dispatch, 2-minute setup then button-only sleep, timer wake, discovery + bind (or `CONFIG_SIOT_LEAF_BENCH_PARENT_MAC`), `HEARTBEAT` with the leaf ACK path, mailbox / outbox plumbing, button walk test / survey, post-provisioning verdict, `awake_ms` on UART0, sleep-mode Kconfig, mock sensor + battery — `apps/leaf`, `net/siot_leafcore`, `platform/siot_sensor` | Devkit sleeps, wakes every 60 s, logs one line per wake; 791 KB image | **Done in code 2026-09-28** — bench pending (L1–L3, L14) |
| 3. Parent role on the node (`features/siot_leafmgr`) | Raw sink on `siot_survey`, TX + downlink hooks on `siot_netcore`, 9-byte ACK with `PENDING` / `NO_PATH` / `EPOCH` / `CHANNEL`, leaf table with boot-scoped replay/dup, forward every leaf frame up, custody (identical-bytes retries; board forwards replays to the tablet), mailbox with immediate delivery to an awake leaf, offer with `0xFF` when not online; pure parts in `siot_leaf_proto` (rx check, mailbox, custody — 3 more host tests) | Leaf devkit + node devkit + board + tablet: leaf appears on Rede with role 2, green after provisioning, blue → cyan on TEST | **Done in code 2026-09-28** — bench pending (L2, L3, L7, L11) |
| 4. Leaf link complete | Probe / bind / back-off, `NAME_ANNOUNCE` once, `TOPOLOGY` per bind, outbox, alarm tiers incl. broadcast fallback, button verdict, post-provisioning verdict | Bench items below | — |
| 4b. Tablet | Leaf states per `docs/devices/leaf.md` §8b: Acordado / Dormindo with wake countdown / Sem comunicação "há X"; `parentCandidates` column in `MeshDevices` (+ reference §3.6.1) fed by the leaf's bind-time TOPOLOGY; "pais ao alcance" fact and weak-link / single-parent warning on the sheet and in the walk-test report | Rede map reads a leaf correctly without anyone explaining it | **Done in code 2026-09-28** (Drift v9, ingest test) — bench T1–T4 pending |
| 5. Bench pass | Checklist §6 | All ticked | — |
| 6. POC D | Wake measured with a meter; pack chosen; reference §4 battery line filled | A number, not an estimate | — |

Build rules as everywhere: IDF 5.5.2 only, header before docs, `idf.py build` green on board, node,
leaf and host before any step is called done; never two builds in parallel.

## 6. Bench checklist

Legend: `[ ]` pending (bench) · `[x]` done.

- [ ] **L1** Setup window: leaf devkit white-blinks 2 min, then sleeps; button press brings the window back; provisioning from the phone → `stored`.
- [ ] **L2** Post-provisioning verdict: blinks per candidate, then green 3 s (node devkit online) or one red (node off); leaf sleeps.
- [ ] **L3** Heartbeat: one wake per 60 s, `awake_ms` ≤ 500 logged; tablet shows the leaf under its parent, "Na placa: online", role 2.
- [ ] **L4** Missing: unplug the leaf → tablet and board mark it missing at ≈ 180 s; plug back → restored on the first frame.
- [ ] **L5** Parent loss: power off the node → leaf re-probes on the 2nd miss and binds to a second node within ≈ 120 s, no trouble on the panel; with no node at all → COMM_FAULT blink + chirp each wake, 5-min back-off when nobody answers.
- [ ] **L6** `NO_PATH`: node up, board off → leaf's ACK carries `NO_PATH`; a press runs the survey, not the walk test.
- [ ] **L7** Walk test: press on a bound leaf → `MANUAL_TEST` on the tablet with time and RSSI; blue then **cyan** on the leaf.
- [ ] **L8** Alarm: double tap → ALARM latched on the tablet; leaf stays awake, red, re-announces every 60 s; RESET from the tablet reaches it through the mailbox / live path and it sleeps.
- [ ] **L9** Alarm fallback: double tap with the bound node powered off and a second node in reach → alarm arrives by broadcast through the second node; one entry on the tablet.
- [ ] **L10** Outbox: double tap with no node in reach, then power a node → ALARM + RESTORE arrive on the next wake with the original timestamps, journaled in order.
- [ ] **L11** Mailbox: rename the sleeping leaf on the tablet → "pendente" → applied on the next wake, `NAME_ANNOUNCE` follows; then rename while its parent is off and it rebinds elsewhere → still applied (board re-originates).
- [ ] **L12** Decommission through the mailbox → leaf back to white blink for 2 min, then sleeps.
- [ ] **L13** Clock and channel: leaf timestamps follow the tablet's clock via `EPOCH`; change `CHANNEL` in the ACK on the bench → leaf switches.
- [ ] **L14** Survey from the leaf with the board off and two nodes powered: two blinks in their colours; press towards the sleeping leaf from a node: no answer (documented).
- [ ] **L15** 24 h soak: no missed wake, `awake_ms` stable, zero auth failures.
- [ ] **T1** Tablet: a healthy leaf reads **Dormindo** between wakes with "último despertar / próximo em", never OFFLINE; **Acordado** right after a press and while an alarm is latched.
- [ ] **T2** Tablet: leaf unplugged → **Sem comunicação há X** at ≈ 180 s plus the "dispositivo ausente" trouble; back → restored on the first frame; dimmed at 10 min.
- [ ] **T3** Tablet: with one node in reach the sheet shows "Pais ao alcance: 1" and the single-parent warning; with two, no warning; a link below −85 dBm shows the weak-link warning; the walk-test report flags the same.
- [ ] **T4** Tablet: IDENTIFY sent to a sleeping leaf → sheet says "pendente: aplica quando o detector acordar" → the leaf blinks on its next wake.

## 7. Open risks

1. Mesh-Lite + ESP-NOW coexistence on the parent while it is a root (Phase 1 brief §14 item 16); survey proved the node side with the board off, not with a live mesh under load.
2. The leaf's 100 ms ACK wait assumes the parent answers from its own queue without touching the mesh; measure it.
3. Awake time of a real wake (PHY init + one frame + ACK) is unmeasured; the 300 ms figure is an estimate and the 500 ms budget must hold with the mock sensors in the loop.
4. Standards' battery-life minimums and the 200 s / 300 s limits are recalled, not read from the purchased editions.
5. The detector PCB may share hardware with the AC detector; on mains the same unit would run as a node. Deep sleep itself does not depend on the supply.
