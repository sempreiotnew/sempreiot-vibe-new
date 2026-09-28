# SempreIoT — Push-button station (`SIOT-PBS-01`)

_2026-09-28. Product page. Family page: `node.md`. Catalogue: `docs/sempreiot-system-reference.md` §2.1.
The reference wins on conflict._

**Status in one line:** a `SIOT-PBS-01` unit is a **node** with no station behaviour yet. Stamped with
`tools/flash.sh node <port> --model SIOT-PBS-01`, it behaves like the bench node. The station input
("someone pressed the alarm") is a planned feature.

---

## 1. Definition

A mains-powered **manual call point**: a person raises the alarm by hand. An **AC device** (blueprint §0):
Mesh-Lite node, root-capable, always awake, a leaf parent. Its own job is to turn a press of the station
into an **`EVENT ALARM`** that the board latches and every siren answers.

What it is not: not the TEST button (the small RST/TEST button on every unit raises a *supervisory*
`MANUAL_TEST`, never an alarm); not a detector; not the board.

## 2. Hardware

| Item | Value | Source |
|---|---|---|
| Module | ESP32-S3-WROOM-1-**N4** | reference §4.1 |
| Firmware image | **node** | reference §2.1 |
| Model string | `SIOT-PBS-01` in `nvs_factory` | reference §2.1 |
| Power | Mains, battery backup (ACOK 5, BOOST 6, CHG 7) | spec §7.1.3 |
| Station input | **PCB pending.** The break-glass / push element on a supervised input (open / pressed / wire-fault as three states) — GPIO to be assigned in `pinmap.yaml` | — |
| Reset of the station | Mechanical (key / reset tool) on the element; the *panel* latch clears only by the operator's `RESET` | spec §7.1.4 |
| LED / button | RGB 14 / 47 / 48, RST/TEST 21 | `pinmap.yaml` |

## 3. Rules that bind a station (on top of the node rules)

1. A press is an **ALARM**, not a test: `EVENT ALARM`, `F_ACK_REQ`, 3 fast retries, re-announced every 60 s
   until `RESET` (spec §7.2). The event code needs a value of its own (**`MANUAL_ALARM`, to add** to
   spec §7.1.2 — `MANUAL_TEST` 0x04 is the walk test and must stay distinct).
2. **Latching** is the board's / tablet's (spec §7.1.4): the station's own element may be reset by hand,
   the panel alarm stays until the operator resets.
3. The station **keeps re-announcing while the element is pressed**; a `RESTORE` follows when the element
   is reset (the panel records it, the latch does not clear — §7.1.4).
4. The input is **supervised**: a wire fault is a `TROUBLE` (`SENSOR_FAULT` or a station-specific code),
   ⛑ UL 864 / EN 54-11 supervision of the call point.
5. Everything else is the node's.

## 4. Behaviour today (inherited from the node image)

As `siren.md` §4: mesh, failover, leaf parent role, walk test on the RST/TEST button, lifecycle commands,
`IDENTIFY`. A press of the (future) station input does nothing until the feature exists.

## 5. Planned behaviour — the `siot_station` feature

| Ref | Function | What the feature adds | Spec |
|---|---|---|---|
| 5.1 | Alarm from a press | `EVENT ALARM MANUAL_ALARM` with the §7.2 delivery rules; local red LED; sirens sound on overhearing it | spec §7.1, §7.2 (new code) |
| 5.1 | Restore | `RESTORE` when the element is reset; latch untouched | spec §7.1.4 |
| — | Input supervision | wire-fault trouble; input state in `PWR_FLAGS` / `FAULT_FLAGS` reserved bits | spec §7.1.3, §7.1.5 |
| 5.8 | Power troubles | as the node | spec §7.1.2 |
| 7.4 | OTA | node image, per-model rollout | OTA blueprint |

Adding it = `firmware/components/features/siot_station/` enabled for `SIOT-PBS-01`, the `MANUAL_ALARM`
code in the spec first, the input pin in `pinmap.yaml`.

## 6. LED language

The node's, plus **red solid while the station is in alarm** (already the alarm-latched colour).

## 7. Open items

1. Input electrical design (supervised loop resistors) and the three-state read.
2. `MANUAL_ALARM` event code and whether the tablet shows a distinct "acionamento manual" text.
3. Standards to verify: EN 54-11 (manual call points) / NFPA 72 manual fire alarm boxes — response time,
   supervision, reset method.
4. PCB GPIO map (`docs/spec/definition-station.md`, to write).

## 8. Where it lives

Image `firmware/apps/node`; pin map `SIOT-PBS-01` (family node); feature
`firmware/components/features/siot_station/` (not yet). Specs: reference §2.1, rows 5.1 / 5.3; spec §7.1,
§7.2, §7.1.4; blueprint §6.
