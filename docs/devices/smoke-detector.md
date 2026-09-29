# SempreIoT — Battery smoke detector (`SIOT-SMOKE-01`)

_2026-09-28. Product page. Family page: `leaf.md` (the whole leaf link — wake cycle, parent, mailbox,
button, tablet states — is inherited from there). Catalogue: `docs/sempreiot-system-reference.md` §2.1.
The reference wins on conflict._

**Status in one line:** a `SIOT-SMOKE-01` unit is a **leaf** with mocked sensors. Stamped with
`tools/flash.sh leaf <port> --model SIOT-SMOKE-01`, it wakes every 60 s, binds to a node, heartbeats,
runs the walk test and the survey — everything in `leaf.md` — and reports a fixed clean-air reading. The
real sensing (ADPD188BI smoke, HDC2080 temperature, thresholds, pre-alarm) is the sensing phase
(reference row 5.5).

---

## 1. Definition

A battery-powered smoke detector: a **leaf** (blueprint §0). Sleeps, wakes on its 60 s timer or on the
sensor's interrupt, talks ESP-NOW to one parent node, never routes. Its own job is to **detect smoke and
raise `EVENT ALARM SMOKE_ALARM`**, and to warn early with `ALERT SMOKE_RISING`.

What it is not: never root, never relay, never associated to Wi-Fi except for the OTA pull; not a heat
detector (that is `SIOT-HEAT-01`, a later row, same image).

## 2. Hardware

| Item | Value | Source |
|---|---|---|
| Module | ESP32-S3-WROOM-1-**N4** | reference §4.1 |
| Firmware image | **leaf** (`firmware/apps/leaf`, no Mesh-Lite) | reference §2.1 |
| Model string | `SIOT-SMOKE-01` in `nvs_factory` | reference §2.1 |
| Power | Batteries; pack and life to be decided by POC D | reference §4, spec §12.12 |
| Smoke sensor | **ADPD188BI** optical (blue + IR LEDs, heater), I2C on GPIO 1 / 2, wakes the ESP on GPIO 4 (`DTR_SLEEP`) | `docs/spec/definition-detector.md` |
| Temperature / humidity | **HDC2080**, same I2C bus, same wake line | `definition-detector.md` |
| Battery | ADC on GPIO 10 (BATT), NTC on 9; BOOST 6 / CHG 7 / ACOK 5 states | `definition-detector.md`, spec §7.1.3 |
| Tamper | GPIO 11 (removed from base) | spec §7.1.2 0x05 |
| Sounder | local alarm sounder (PCB pending) — a leaf in alarm sounds locally while it re-announces | spec §12.6 |
| LED / button | RGB 14 / 47 / 48, RST/TEST 21 = wake pin | `leaf.md` §2 |

## 3. Rules that bind a smoke detector (on top of the leaf rules)

1. **The sensor samples on its own; the ESP sleeps.** The ADPD188BI runs its own sampling and raises GPIO 4
   on threshold; the ESP never polls (blueprint §5.1, spec §12.2 budget).
2. **Alarm = awake until the board's ACK**, re-announced every 60 s, local sounder on, broadcast fallback
   if the parent is gone (spec §12.6).
3. **Pre-alarm** (`ALERT SMOKE_RISING`, spec §7.1.2 0x03) is supervisory, not latched.
4. **Raw values reported** in every EVENT (`SMOKE`, `TEMP`, `HUMIDITY` fields) so thresholds can be
   verified by a lab (reference row 5.5).
5. **Battery warning** `BATT_LOW` at ≥ 7 days remaining (NFPA 72), ~30 days target (EN 54-25); `BATT_CRITICAL`
   before shutdown (spec §7.1.2). Tamper is a `TROUBLE`.
6. Standards to verify: EN 54-7 / UL 268 (smoke detectors), EN 54-25 / NFPA 72 (radio, battery life).

## 4. Behaviour today (inherited from the leaf image)

Everything in `leaf.md` §4 with the **mock sensor backend** (`components/platform/siot_sensor`,
`CONFIG_SIOT_SENSOR_MOCK`): smoke raw 120 (clean air), 25.0 °C, 45 % humidity, battery 100 %. The test
button is the walk test / survey; **double tap = bench ALARM** stands in for smoke.

## 5. Planned behaviour — the sensing phase (reference row 5.5)

| Ref | Function | What it adds | Spec |
|---|---|---|---|
| 5.5 | Smoke / heat detection | Real `siot_sensor` backend (ADPD188BI + HDC2080 drivers, I2C via `driver/i2c_master.h`), sensor-interrupt wake, thresholds with trend for pre-alarm, `SENSOR_FAULT` on I2C failure | spec §7.1, `definition-detector.md` |
| 5.8 | Battery and tamper | ADC battery model → `BATTERY_PCT` and the 7-day rule; tamper input | spec §7.1.2 / §7.1.3 |
| — | Local sounder | sounds during an alarm; trouble chirp per wake in COMM_FAULT (log line today) | spec §12.8 |
| 7.4 | OTA | leaf image, pull on wake, battery ≥ 60 % | OTA blueprint §3.5 |

Adding it = the real backend in `siot_sensor` (selected for `SIOT-SMOKE-01`; the heat detector reuses it
with a different threshold set), pins already in `pinmap.yaml` for the sensors when the PCB arrives.

## 6. LED language

The leaf's (`leaf.md` §7): nothing while asleep; after provisioning and on a press the same thing: blue → cyan on a walk test (one red = no answer), one
blink per answering unit on a survey; red solid + sounder in alarm; red blink + chirp per wake in
COMM_FAULT.

## 7. Open items

1. POC D: battery pack, measured wake cost, life against the standards.
2. Sensor thresholds and the pre-alarm trend; lab verification of raw values.
3. Chamber / housing and the tamper mechanics (hardware).
4. Whether the smoke and heat products share `SIOT-SMOKE-01` with a config, or get `SIOT-HEAT-01` (a row is
   reserved for the latter).

## 8. Where it lives

Image `firmware/apps/leaf`; runtime `components/net/siot_leafcore`; sensors `components/platform/siot_sensor`
(mock); pin map `SIOT-SMOKE-01` (family leaf). Specs: reference §2.1, rows 2.7 / 5.5 / 5.8 / 6.8; protocol
§12; `docs/spec/definition-detector.md`; `docs/phases-development/phase2-leaf-brief.md`.
