# SempreIoT — Siren (`SIOT-SIREN-01`)

_2026-09-28. Product page: what this unit is, what it does today, what it will do, and where that is
specified. Family page: `node.md` (everything an AC device does is inherited from there). Catalogue:
`docs/sempreiot-system-reference.md` §2.1. The reference wins on conflict._

**Status in one line:** a `SIOT-SIREN-01` unit is a **node** with no siren behaviour yet. Stamped with
`tools/flash.sh node <port> --model SIOT-SIREN-01`, it joins the mesh, relays, parents leafs and answers
the walk test exactly like the bench node. The sounder, `COMMAND SOUND` and "sound on any overheard
alarm" are the `siot_siren` feature, planned (reference rows 5.2, 5.6).

---

## 1. Definition

A mains-powered sounder for the installation: an **AC device** (blueprint §0), so a Mesh-Lite node,
root-capable, always awake, a parent for battery leafs. Its own job is to **sound** when the board says
so, and to sound on its own when it overhears an authenticated alarm, board reachable or not
(blueprint §6.3, rule that survives a dead board — blueprint §7).

What it is not: not a detector (no sensors), not a control unit (it never latches for the site; the
board does), not a leaf (never sleeps).

## 2. Hardware

| Item | Value | Source |
|---|---|---|
| Module | ESP32-S3-WROOM-1-**N4** (4 MB, no PSRAM), N8R8 fallback | reference §4.1 |
| Firmware image | **node** (`firmware/apps/node`, 4 MB table) | reference §2.1 |
| Model string | `SIOT-SIREN-01` in `nvs_factory` (`tools/flash.sh --model`) | reference §2.1 |
| Power | Mains, battery backup on the PCB (ACOK 5, BOOST 6, CHG 7 → `PWR_FLAGS`) | spec §7.1.3 |
| Sounder | **PCB pending.** Placeholder: relay on GPIO 12 (`RELAY_SET`) drives the sounder; a PWM-driven piezo/horn with a temporal pattern is the target | `docs/spec/definition-detector.md` (relay), `pinmap.yaml` |
| LED / button | RGB 14 / 47 / 48, button 21 (TEST / factory reset), devkit wiring until the PCB map exists | `pinmap.yaml` |

## 3. Rules that bind a siren (on top of the node rules)

1. **Sounds on any authenticated ALARM it overhears**, from any unit, whether or not the board is
   reachable (blueprint §6.3 default rule; §7 "board dies": sirens keep sounding).
2. **`SILENCE` stops the sounder and keeps the alarm latched** at the panel; only `RESET` clears the
   latch (spec §7.6 0x01, §7.1.4). A silenced siren sounds again on a *new* alarm.
3. **Cause-and-effect** is the board's: `COMMAND SOUND` to selected sirens (blueprint §6.3); the
   overheard-alarm rule is the floor, never the ceiling.
4. Sound pattern: the evacuation signal of the target standard (temporal-3 for NFPA 72 / ISO 8201; EN 54-3
   defines sound level and pattern tolerances) — **to verify against the purchased editions** (reference §4).
5. Everything else is the node's: heartbeat 15 s, topology 60 s, leaf parent role, walk test, lifecycle.

## 4. Behaviour today (inherited from the node image)

| Ref | Function | On a `SIOT-SIREN-01` today |
|---|---|---|
| 2.2–2.5 | Mesh, failover, uplink / downlink | as the node |
| 2.7 | Parent role for leafs | as the node (`features/siot_leafmgr`) |
| 5.2 | `SILENCE` / `RESET` | acknowledged, no sounder to act on |
| 5.3 | Test button | `MANUAL_TEST` walk test, survey without a path |
| 5.4 | `IDENTIFY` | blue blink |
| 7.1 | Rename / retire / replace / decommission | as the node |

## 5. Planned behaviour — the `siot_siren` feature (reference rows 5.2, 5.6)

| Ref | Function | What the feature adds | Spec |
|---|---|---|---|
| 5.6 | Sirens and cause-and-effect | Sounder driver (pattern, level); **`COMMAND SOUND`** (undefined today — to be added to spec §7.6 with pattern / duration args); sound on overheard ALARM | blueprint §6.3; spec §7.6 |
| 5.2 | SILENCE | stops the sounder, latch untouched; resound on a new ALARM | spec §7.6 0x01 |
| 5.8 | Power troubles | AC lost / on battery / charging as troubles (node-wide) | spec §7.1.2 |
| — | Supervision of the sounder | `FAULT_FLAGS` bit for a failed sounder / relay (`RELAY_FAIL` exists) | spec §7.1.5 |
| 7.4 | OTA | node image, per-model rollout | OTA blueprint |

Adding it = one component `firmware/components/features/siot_siren/` enabled when the model is
`SIOT-SIREN-01` (features/README.md contract), a `COMMAND SOUND` row in the spec first, and the PCB's pins
in `tools/pinmap/pinmap.yaml`.

## 6. LED language

Exactly the node's (reference row 7.7): white blink setup · white breathe finding the network · green
flash root / off child · blue / cyan traffic pulses · red solid = alarm latched (this unit sounding).

## 7. Open items

1. Sounder hardware and drive (relay vs PWM), sound level, the temporal pattern per standard.
2. `COMMAND SOUND` layout (pattern, duration, which sirens) in the protocol.
3. Whether a siren in alarm keeps sounding after `SILENCE` when it later hears a *different* unit's alarm
   (yes by the rule above) — confirm with the standard's re-sound requirements.
4. PCB GPIO map (`docs/spec/definition-siren.md`, to write).

## 8. Where it lives

Image `firmware/apps/node`; pin map `tools/pinmap/pinmap.yaml` (`SIOT-SIREN-01`, family node); feature
`firmware/components/features/siot_siren/` (not yet). Specs: reference §2.1, rows 5.2 / 5.6 / 5.8;
blueprint §6, §7; spec §7.1.4, §7.6.
