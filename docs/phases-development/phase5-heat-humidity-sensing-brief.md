# Phase 5 brief — Heat and humidity sensing with the HDC2080

_2026-11-26. Planning only: no code, protocol text or other doc was changed for anything below.
Authority: below the protocol and the blueprint. Source for every sensor fact: the datasheet on disk,
`docs/datasheets/hdc2080.pdf` (TI SNAS678C, rev. July 2021) — section numbers in §2 are the
datasheet's. Sibling briefs: `phase2-leaf-brief.md` (the battery unit), `phase4-cause-and-effect-brief.md`
(§2.1: the sensing behaviour is one feature component, `siot_sensing`, compiled into both images).
Reference row this implements: `docs/sempreiot-system-reference.md` row 5.5 (temperature half; the
ADPD188BI smoke half is a separate brief)._

Tags: **[decided]** by the product owner on 2026-11-26 · **[adopted]** a recommendation used for
planning that the product owner did not explicitly confirm — confirm before the protocol revision ·
**[proposed]** a number chosen here, to be tuned on the bench · **[open]** still owed ·
**[hardware]** owed by whoever owns the PCB · **[bench]** the datasheet does not settle it, one unit
on the table will.

---

## 1. What was asked (2026-11-26)

1. Use the HDC2080 (temperature + humidity, I2C) on the detector.
2. AC and battery units behave differently: the battery unit only measures when it is awake; how often
   an AC unit can measure is unknown.
3. Keep the last measurements, because one rule needs to know how many degrees the temperature drifted.
   Where they are kept (the ESP32 or the central) is undecided.
4. The I2C bus has to be **enabled** before measuring.
5. The sensor has an interrupt line (`DTR_SLEEP`) that must be set up correctly; the datasheet warns
   that the pin reflects only one interrupt source at a time.
6. Rules known so far: **above 57 °C → alarm**; **average temperature up 8 °C in a short time →
   alarm**; **humidity above 99.7 % → triggers**.
7. Find the best way to show the measurements and the information to the users.

## 2. What the datasheet says, in the order it matters to us

### 2.1 Ranges and accuracy (§7.3, §7.5)

| | Value | Consequence |
|---|---|---|
| Temperature element, operating | −40 … 125 °C | 57 °C is far inside it. |
| Temperature accuracy | ±0.2 °C typ; **±0.4 max in 10–35 °C, ±0.7 max in 5–60 °C**; repeatability ±0.1 °C | At 57 °C the reading can be 0.7 °C off. Outside 5–60 °C no maximum is given at all. |
| Humidity element, operating | **−20 … 70 °C**, 0–100 % **non-condensing** | This is the "−20 to +60" in the request: it is the humidity element and the accuracy band, not a limit of the temperature reading. |
| Humidity accuracy | ±2 % typ, ±3 % max, and **±3 % typ above 80 %** (Fig. 11-1); hysteresis ±1 %; drift ±0.25 %/year | A 99.7 % threshold is ten times finer than the sensor's accuracy up there — see §6.3. |
| Humidity response | 8 s to reach 63 % of a step | |
| Supply | 1.62–3.6 V; 50 nA asleep; 0.55 µA average at 1 sample/s | The sensor's own consumption is irrelevant next to the ESP32's. |
| Conversion time | 610 µs (T, 14 bit) + 660 µs (RH, 14 bit); ready 3 ms after power-up | A reading costs ≈ 1.3 ms. |

Prolonged exposure above 80 % RH or outside the temperature band shifts the humidity reading, with
slow recovery (§11.1.1.4).

### 2.2 Two ways to measure (§8.3.2)

- **On demand:** the ESP writes `MEAS_TRIG` (0x0F bit 0), the sensor converts once and sleeps again.
- **Auto measurement (AMM, 0x0E bits 6:4):** the sensor measures by itself at 1/120, 1/60, 0.1, 0.2,
  1, 2 or 5 Hz, **with the ESP asleep**, and can raise its pin when a threshold is crossed.

TI recommends **at most 1 sample/s** to avoid the sensor heating itself (§9.2.1).

### 2.3 Reading (§8.6.1–8.6.4)

- Address `0x40` (ADDR to GND or open) or `0x41` (ADDR to VDD).
- One read of 4 bytes from register `0x00`: T low, T high, RH low, RH high (LSB first, mandatory).
- `T(°C) = raw / 65536 × 165 − 40.5` — note **40.5**, changed in datasheet rev. C; most public
  libraries still use 40 and read 0.5 °C high.
- `RH(%) = raw / 65536 × 100`.
- Above 1.8 V supply there is a small correction, 0.08 °C per volt (§8.6.2 eq. 2).
- Identity for the boot probe: manufacturer `0x4954` (0xFC/0xFD), device `0x07D0` (0xFE/0xFF).
- Every configuration register is volatile: after any power loss the sensor is back to defaults
  (no auto mode, no interrupt, pin floating).

### 2.4 The interrupt pin (§8.3.4, §8.3.5, §8.6.5, §8.6.8, §8.6.15)

- Four threshold interrupts — temperature high (TH), temperature low (TL), humidity high (HH),
  humidity low (HL) — plus data-ready (DRDY). Enabled in 0x07, status in 0x04.
- **The pin shows only one of them**, by fixed priority TH > TL > HH > HL. With TH enabled the pin
  ignores humidity completely. It is not an OR.
- The thresholds are **8-bit registers** (0x0A–0x0D), much coarser than the 14-bit reading:
  - temperature: one step = **0.64 °C**. 57 °C falls between code 151 (56.83 °C) and 152 (57.47 °C).
  - humidity: one step = 0.39 %. The highest code, 255, is **99.61 %** — 99.7 % cannot be programmed.
- **Only absolute thresholds exist. There is no rate-of-rise in the chip.**
- `INT_MODE` (0x0E bit 0): `0` = the status bit and the pin **stay asserted until the ESP reads
  register 0x04**; `1` = the pin follows the current reading. `INT_POL` (bit 1) picks active low or
  high. `DRDY/INT_EN` (bit 2) must be 1 or the pin floats.
- Reading 0x04 clears **all** status bits at once: read it once per wake and keep the byte.
- The pin is a **push-pull** output (Table 6-1).
- The peak registers (0x05 / 0x06, maximum T / RH) do not work in auto mode.

### 2.4.1 The datasheet's note on the pin, and what this design does with it

The note (§8.3.4), in full:

> When multiple bits are enabled, the DRDY/INT pin can only reflect the status of one interrupt bit
> at a time. The DRDY/INT pin DOES NOT function as the logical 'OR' of interrupt bits that have been
> enabled. The highest priority is given to TH_ENABLE bit, followed by TL_ENABLE, HH_ENABLE, and
> HL_ENABLE bits in descending order. Therefore, programming recommendations are provided as below:
> - The DRDY/INT will track the HL_ENABLE if enabled and all other ENABLE bits are disabled
> - The DRDY/INT will track the HH_ENABLE if enabled and the TH_ENABLE and TL_ENABLE are disabled
> - The DRDY/INT will track the TL_ENABLE if enabled and the TH_ENABLE is disabled
> - The DRDY/INT will track the TH_ENABLE if enabled and is independent of other ENABLE bit settings

What follows from it for us:

| Consequence | What the design does |
|---|---|
| One pin, one source. Heat and humidity cannot both wake the ESP. | Register 0x07 is written with **TH_ENABLE only**; TL, HH, HL and DRDY stay 0. The pin means exactly one thing: "temperature is above the armed threshold". |
| With TH enabled, a humidity crossing never reaches the pin. | Humidity is never expected from the pin. The firmware reads the humidity value itself and judges it (§6.3): every second on an AC unit, at the 60 s wake on a battery unit. |
| TH wins whatever else is enabled. | Enabling anything else would add nothing to the pin and could only confuse the status byte, so nothing else is enabled. |
| The note ranks the four thresholds but does not say where **DRDY_ENABLE** stands. | DRDY stays disabled: at 1 sample/s it would otherwise wake the battery unit every second. Data is read on our own timing, not on a data-ready pulse. |
| The note speaks for the pin, not for the status bits in 0x04. | Nothing relies on a status bit whose enable is off. Whether HH_STATUS would still set with only TH enabled is a **[bench]** curiosity, not a dependency. |
| The firmware must not "also enable humidity later" as a convenience. | Written as a rule in the driver's header and checked by the configuration read-back at every wake (§5.1): 0x07 must read back as TH only. |

### 2.5 Heater (§8.3.3)

A built-in heater to dry condensation off the humidity element: **90 mA at 3.3 V**, and it raises the
temperature reading while on. **Not used in this phase** (§12).

## 3. Decisions

### 3.1 Taken by the product owner (2026-11-26) **[decided]**

1. **Rate-of-rise window = 60 s**: 8 °C within 60 s. One named constant, revisited if the
   certification standard (O1) says otherwise.
2. **Everything is in Celsius**, on the unit, on the wire and on screen.
3. **Humidity above 99.7 % is a TROUBLE, not an ALARM**, with its own event code, consecutive
   readings and a lower release figure.
4. **The final product runs the sensor at 1.8 V behind the level shifter; the development unit runs
   it at 3.3 V.** Development and bench happen at 3.3 V, with the firmware behaving as on the final
   product (§9).
5. **The I2C wires go through a level shifter on the final board** (the PCA9306 enabled by GPIO 38,
   as `docs/spec/definition-detector.md` shows). Whether the *interrupt* wire is also level-shifted
   is still H2.
6. **The sensor keeps measuring while the battery unit sleeps.** At 1 sample/s it draws 0.55 µA,
   about 5 mAh per year. Measuring only at the 60 s wake would save that and nothing else, would
   notice a fire up to 60 s late, and would leave the rate-of-rise rule one sample per minute. The
   battery cost that matters is the ESP waking for nothing (§13 risk 2), not the sensor.
7. **The interrupt line (DTR) is tested in the first version**, on the 3.3 V development unit (§10
   step 5).
8. **UI: the chart is in the first version; every user sees everything** (no values hidden behind
   the installer PIN); a temperature pill on each detector card plus current values and a one-hour
   chart on the device screen (§8).

### 3.2 Adopted for planning — confirm before the protocol revision **[adopted]**

1. **Two heat event codes**: the existing `HEAT_ALARM` (fixed temperature) and a new one for
   rate of rise, so the screen and the history can say why it fired.
2. **No heat pre-alarm** (`HEAT_RISING` ALERT) in the first version.
3. **`HUMIDITY` is added to the HEARTBEAT**, otherwise the device screen and the chart have no
   humidity while everything is normal (today it travels in EVENT only).
4. **Thresholds are fixed in the firmware**, not settable from the central.
5. **The rise amount is not put on the wire.** A rate-of-rise alarm shows "subida rápida" and the
   current reading, not "subiu 9 °C".

## 4. Thresholds and numbers — every figure used, in one place

All temperatures in °C. Where a figure is **[proposed]**, it is a starting value chosen in this brief
and nothing else depends on it being exact.

### 4.1 Measurement

| What | Value | Status | Why |
|---|---|---|---|
| Sample rate, both families | 1 sample per second (sensor auto mode, AMM = 1 Hz) | [decided] | the datasheet's ceiling against self-heating |
| Resolution | 14 bit temperature, 14 bit humidity | [proposed] | costs 1.3 ms per sample |
| I2C speed | 100 kHz (the sensor allows 10–400 kHz) | [proposed] | |
| Wait after sensor power-up | 3 ms | datasheet | |
| Wait after opening the level shifter (GPIO 38) | 1 ms | [proposed] [bench] | |
| Supply correction | −0.08 °C × (supply − 1.8 V): −0.12 °C at 3.3 V, 0 at 1.8 V | datasheet | one build setting |
| Enclosure offset (register 0x08, 0.16 °C steps) | 0 | [open] | measured in the real housing |

### 4.2 Heat — fixed temperature

| What | Value | Status |
|---|---|---|
| Alarm threshold | reading ≥ **57.0 °C** | [decided] |
| Confirmation | 3 consecutive samples (3 s at 1 Hz) | [proposed] |
| Chip wake threshold (battery unit) | register code **151 = 56.83 °C**: the last step at or below 57 °C, so the chip never wakes the ESP later than the rule needs | derived |
| Unit reports "back to normal" (RESTORE) | reading < 54.0 °C for 60 consecutive samples | [proposed] |

The central's alarm latch is unaffected: only an operator RESET clears it (protocol §7.1.4).

### 4.3 Heat — rate of rise

| What | Value | Status |
|---|---|---|
| Alarm threshold | rise ≥ **8.0 °C** | [decided] |
| Window | **60 s** | [decided] |
| "Average temperature" | the current value is the mean of the 4 newest samples | [proposed] |
| Reference, AC unit | the mean of the 4 samples taken 60–63 s ago | [proposed] |
| Reference, battery unit | the reading of its last 60 s wake while that is no more than 60 s old, then its own 1 Hz samples from 60 s ago | [proposed] |
| Battery unit wake margin | chip threshold = reading at the last 60 s wake **+ 4.0 °C**, rounded down to the 0.64 °C step, never above code 151 | [proposed] [bench] |
| Battery unit confirmation | awake sampling at 1 Hz for at most 60 s after a sensor wake, then re-arm and sleep | [proposed] |
| Power-up guard | no rate-of-rise during the first 120 s after power-up | [proposed] — O3 |
| Floor temperature | none in the first version | [open] — O3 |

### 4.4 Humidity trouble

| What | Value | Status |
|---|---|---|
| Trouble threshold | reading ≥ **99.7 %**, compared on the full-resolution reading inside the unit | [decided] |
| Confirmation, AC unit | 10 consecutive samples (10 s) | [proposed] |
| Confirmation, battery unit | 2 consecutive 60 s wakes | [proposed] |
| Release (RESTORE) | reading < 95.0 %, same counts | [proposed] |
| On the wire and on screen | whole percent | protocol §7.1 |

### 4.5 Sensor fault

| What | Value | Status |
|---|---|---|
| Fault | wrong identity at boot, or 3 consecutive failed I2C exchanges, or the configuration read back differs from what was written | [proposed] |
| Restore | 3 consecutive good readings after a successful re-configuration | [proposed] |

### 4.6 History and screen

| What | Value | Status |
|---|---|---|
| AC unit history | last 64 samples (64 s) in RAM | derived from §4.3 |
| Battery unit history | last 60 s reading plus up to 64 samples while awake, in RTC memory | derived |
| Tablet history | one point per frame that carries a temperature; kept **24 hours** per device | [proposed] |
| Chart on the device screen | last **1 hour**, with the 57 °C line | [decided] |
| Pill turns amber ("subindo") | the tablet's own points show ≥ 4.0 °C within 60 s | [proposed] |
| Pill turns red | the unit is in a heat alarm | [decided] |
| Reading shown as old | always with its age; grey when the unit is offline (the existing offline rule) | [proposed] |

Lowering any of §4.2–§4.4 to make a bench test practical (e.g. 35 °C instead of 57) is a relaxed
rule: a row in `docs/ota/before-production.md` and a line in `firmware/ci/check.sh --release` in the
same change.

## 5. Design

### 5.1 Sensor configuration — the same on both families

| Register | Value | Why |
|---|---|---|
| 0x0F | 14-bit T, 14-bit RH, humidity + temperature | full resolution costs 1.3 ms |
| 0x0E | AMM = 1 Hz, heater off, pin enabled, `INT_MODE = 0` (latched), polarity per H5 | latched: the pin holds until the ESP has woken and read 0x04 — a pulse cannot be missed |
| 0x07 | **TH only** | the pin can only speak for one source; heat is the one that must wake |
| 0x0B | TH code, recomputed by the firmware (§4.2, §4.3) | |

Written at boot after the identity probe; **re-checked at every wake** (3 bytes read back): a sensor
that lost power silently stops watching, and that must become a `SENSOR_FAULT`, not silence.

### 5.2 AC unit (node image)

Never sleeps. A 1 s timer reads the 4 data bytes (the sensor is already converting at 1 Hz), feeds
the rules and keeps the history in RAM. The interrupt pin is not needed for detection; it stays
configured so both families run one driver.

### 5.3 Battery unit (leaf image)

- **Asleep:** sensor at 1 Hz, TH armed, GPIO 4 added to the deep-sleep wake sources next to the
  button (today only the button is there: `siot_leafcore.c:1135`).
- **Timer wake (60 s, unchanged):** read T / RH, store, re-arm TH (§4.3), then the existing
  heartbeat sequence. Cost: one I2C read + one write, ≈ 2 ms extra awake.
- **Sensor wake (new):** read 0x04 (clears the pin), then stay awake sampling at 1 Hz until the
  rules confirm an alarm or stand down. A slow daily drift never reaches the moving threshold (the
  baseline follows every 60 s); a fast rise crosses it within the minute.
- **History:** in RTC memory beside `s_rtc` (survives deep sleep, costs no flash wear, is rightly
  empty after a battery change). Not NVS.
- The number of sensor wakes that did not end in an alarm is counted and reported, so the bench can
  see what the +4 °C margin costs.

### 5.4 Where it goes in the tree

- `components/platform/siot_sensor`: the real HDC2080 backend behind the existing interface
  (`driver/i2c_master.h`, the 5.x driver). The `#error` at `siot_sensor.c:22` already names it.
  New calls needed: arm the threshold, read-and-clear the interrupt status, a health check. It always
  opens the level shifter before a transaction and closes it after (§9).
- `components/features/siot_sensing` (new, both images — phase 4 brief §2.1): the rules, the history,
  host-testable with no hardware.
- The mock backend stays, and gains a scripted temperature ramp so the rules run on a devkit.

## 6. The rules

### 6.1 Fixed temperature

`HEAT_ALARM` (EVENT_CODE 0x02, already in protocol §7.1.2) per §4.2. 57 °C equals the classic
fixed-temperature rating of an ordinary heat detector, so the number is probably normative: the
standard and class (O1) fix the tolerance, the response time and whether the ±0.7 °C sensor error has
to be subtracted from the threshold.

### 6.2 Rate of rise

A new event code (§3.2 item 1), per §4.3: current value minus the reference ≥ 8.0 °C. The chip has
no such function; on the battery unit the moving threshold makes the chip do the watching and the
ESP only wakes to confirm.

### 6.3 Humidity

A TROUBLE with a new event code, per §4.4. What the product owner agreed to and why:

1. **The sensor cannot resolve 99.7 %.** ±3 % up there; in practice the rule means "the element is
   saturated / wet" ("sensor molhado / leitura de fumaça não confiável").
2. **The wire carries whole percent.** The decision is taken on the unit with the full reading; the
   central shows "99" or "100".
3. **The pin cannot wake for it** while TH is enabled (§2.4). On the battery unit humidity is judged
   at the 60 s wake only — fine for something as slow as condensation. **[bench]**: whether the HH
   status bit still sets in 0x04 with TH also enabled (the datasheet only speaks for the pin).
4. **Condensation is not fire**: an ALARM from a ±3 % reading would be a false alarm on every humid
   morning.

### 6.4 Sensor fault

Per §4.5: `SENSOR_FAULT` (0x08) with `FAULT_FLAGS` bit 1 `TEMP_SENSOR` — both exist in the protocol.
`TEMP` / `HUMIDITY` go out as n/a (`0x7FFF` / `0xFF`), already supported.

## 7. Protocol impact (nothing written yet)

| Item | Today | Needed |
|---|---|---|
| `HEAT_ALARM` 0x02, `SENSOR_FAULT` 0x08, `TEMP_SENSOR` fault bit | exist | none |
| Rate-of-rise alarm | — | a new EVENT_CODE, ALARM |
| Humidity trouble | — | a new EVENT_CODE, TROUBLE, cleared by RESTORE |
| `TEMP` in HEARTBEAT | present (node and leaf) | none; it is the chart's source |
| `HUMIDITY` in HEARTBEAT | absent | one byte appended, whole percent, `0xFF` = n/a; receivers must take both lengths |
| Rise amount, thresholds | — | none (§3.2 items 4, 5) |

The code numbers are assigned in the protocol revision, from the first free values in §7.1.2 as it
stands that day. The revision comes **before** the app work.

## 8. UI / UX

### 8.1 Principle

This is a fire panel, not a weather station. The user rarely needs the number; they need to know
whether something is wrong, where, and why. Measurements are quiet while normal and loud only when a
rule fires.

### 8.2 Where each thing goes

| Screen | What the user sees |
|---|---|
| **Principal (home)** | Nothing new while normal. A heat alarm appears like any alarm, with the cause in words: "Calor — 58 °C" (fixed) or "Calor — subida rápida, 41 °C" (rate of rise). The humidity trouble counts among the troubles as "Sensor molhado". |
| **Dispositivos (list)** | One temperature pill on each detector card, neutral while normal, amber while rising, red in a heat alarm (§4.6). No humidity on the card. |
| **Dispositivo (detail)** | The main place: current temperature and humidity, the age of the reading, and the last-hour chart with the 57 °C line. |
| **Eventos / history** | Each heat or humidity event keeps the reading and the reason it fired. |
| **Rede map** | Nothing: the map shows traffic, not readings. |
| **Remote (MQTT) viewers** | The same as the tablet (everything on the central is mirrored). |

Every user sees all of it; nothing is behind the installer PIN.

### 8.3 Three rules of honesty

1. **Age of the reading.** A battery unit reports every 60 s. The number always shows how old it is
   ("há 40 s") and goes grey when the unit is offline. A stale 24 °C shown as current is worse than
   no number.
2. **Humidity in whole percent**, never decimals: the sensor is ±2 to 3 %.
3. **The chart draws real points only**: the points that arrived, gaps where none did, no smoothing
   and no invented values between them.

### 8.4 What it costs in the app

- A **new history table** in the tablet's database (device, time, temperature, humidity; 24 h
  retention) — and reference §3.6.1 updated in the same change.
- The device card, the device screen, the home alarm text, the event texts.
- No LED change: a heat alarm is the existing red through `siot_ui_led` events; no new colour.
- Installer texts name the types as Central / Dispositivo AC / Dispositivo Bateria.

## 9. Development at 3.3 V, product at 1.8 V

Registers, timings, formulas and thresholds are identical at both voltages. The app, the protocol,
the rules, the history and the sleep logic never see the voltage.

| | 3.3 V development unit | 1.8 V final product | How it is handled |
|---|---|---|---|
| Temperature correction | −0.12 °C | none | one build setting (supply in mV) |
| Level shifter (GPIO 38) | absent | must be open while talking to the sensor | the driver **always** opens it, waits, talks, closes it, and closes it before sleep |
| Interrupt wire to GPIO 4 | direct | depends on H1, H2 | hardware only |

Two ways to make the bench behave like the product:

1. **In the firmware (always done):** the shifter sequence runs on every unit. On the development
   unit GPIO 38 drives nothing, so a mistake in the sequence would go unnoticed.
2. **On the bench with real parts (recommended):** a PCA9306 breakout between the ESP32 and the
   sensor, its enable on GPIO 38, and the sensor fed from a small 1.8 V regulator. A forgotten enable
   then makes the sensor stop answering, exactly as on the product. Check first that the sensor
   board accepts 1.8 V (the chip does; some breakouts carry their own regulator or 3.3 V pull-ups).

What stays for the first final board whatever is done now: the interrupt wire at 1.8 V on the shared
net (H1, H2), and the temperature offset inside the real enclosure.

## 10. Steps — order agreed 2026-11-26

**Only one unit carries the sensor.** It starts as an **AC unit** (node image) and is re-flashed as a
**battery unit** (leaf image) for step 5. An AC unit never sleeps, so its log is always there, it
needs no interrupt wire, and it exercises the driver, the rules, the protocol and the app end to
end. Everything written for it is reused unchanged by the battery unit; only the sleep-and-wake part
is new there. Changing family is a cable flash with the other model stamp (phase 4 brief §2.1).

| Step | What | Needs | Visible result |
|---|---|---|---|
| 1 | `siot_sensing`: rules + history, host tests | nothing | scripted curves: 57 °C fires, 8 °C in 60 s fires, a slow drift stays quiet |
| 2 | Mock ramp on devkits, node and leaf | devkits | a real `HEAT_ALARM` crosses the mesh to the tablet |
| 3 | Protocol revision, then the app: texts, pill, device screen, chart, history table | §3.2 confirmed | the tablet shows the mock's temperature, humidity and alarms |
| 4 | HDC2080 driver, the sensor unit as **AC** — including the **DTR pin test, awake** (§10.1 part A) | the sensor unit, H4, pin 4 of the sensor reachable | real readings on the tablet; warm air trips both rules; unplugging the sensor gives `SENSOR_FAULT`; the log shows GPIO 4 firing, holding and clearing |
| 5 | The sensor unit re-flashed as **battery**: GPIO 4 as a deep-sleep wake source, moving threshold, RTC history — the **DTR wake test** (§10.1 part B) | H5 | asleep, the unit wakes by heat alone; awake time and current measured |
| 6 | Docs (reference row 5.5, `docs/devices/*.md`, protocol), `idf.py build` of node and leaf, app tests — and the **presentation page** (§10.2) | | a simple HTML page the product owner can be walked through |

### 10.2 The presentation page (step 6)

A single, simple HTML page for presenting the feature to the project owner, written last so that it
describes **what was actually built and measured**, not what was planned. Plain language, no code.
Contents: what the sensor measures and how often; the three rules with their real numbers; how an AC
unit and a battery unit differ (with a picture of the sleep → heat → wake → alarm sequence); what
the user sees on each screen (screenshots of the real app); what was tested on the bench and the
results; and what is still open for the final board (the shared wire, the 1.8 V level, the
enclosure).

### 10.1 The DTR test, on the 3.3 V unit — in two parts

Sensor pin 4 (DRDY/INT) wired straight to ESP32 GPIO 4, nothing else on that wire.

Most of what is uncertain about the pin is about the **sensor**, not about sleep, and is far easier
to see on a unit that is awake with its log running. So the pin is tested first on the AC image
(part A, step 4) and only the wake itself waits for the battery image (part B, step 5). The riskiest
unknown is thereby tested early without starting on the family that is hardest to debug.

| Part A — awake, AC image (step 4) | Part B — asleep, battery image (step 5) | Not proven until the final board |
|---|---|---|
| the pin fires at the programmed threshold | the pin wakes the ESP32 from deep sleep | the wire shared with the smoke sensor (H1) |
| it holds until register 0x04 is read, then releases | the moving threshold across real sleeps: a fast rise wakes, a slow drift does not | the 1.8 V level (H2) |
| polarity and idle level (input to H5) | the sensor keeps its configuration through sleep | |
| the note of §2.4.1 on the real chip: with TH only, a humidity crossing does not move the pin | awake time and current of a heat wake | |
| the moving threshold, re-armed by a 60 s timer standing in for the wake | | |
| whether "over the threshold" is strict (§13 risk 4) | | |

Before wiring: the sensor board must expose pin 4 (some breakouts bring out only power, SDA, SCL).

## 11. Open questions

### 11.1 For the circuit designer **[hardware]**

Worded to be sent as they are.

| # | Question | Why it matters |
|---|---|---|
| H1 | The HDC2080 pin 4 (DRDY/INT) and the smoke sensor's interrupt pin both go to ESP32 GPIO 4. Are they connected directly to each other on the same net, or is there a component between them (diode, transistor, gate)? The HDC2080's pin always drives the wire, high or low — it never releases it — while the smoke sensor's pin only pulls low. | Joined directly, when the two disagree the supply is tied to ground through both chips: the wire sits at an in-between voltage, the ESP32 may miss the wake-up, and current is wasted for as long as it lasts. Source: `docs/spec/definition-detector.md` lines 12, 70, 81 and the datasheet's Table 6-1 ("push-pull output"). A possible conflict, not a confirmed one: the schematic answers it, and "open drain" for the smoke sensor is taken from the spec, not from its datasheet. |
| H2 | The level shifter converts SDA and SCL. Does the interrupt wire (HDC2080 pin 4) also pass through a level converter before the ESP32, or does it arrive at 1.8 V? | A 1.8 V "high" is expected to be too low for a 3.3 V ESP32-S3 input — the exact figure is to be read in the ESP32-S3 datasheet, not assumed. |
| H3 | When the ESP32 is asleep, does the HDC2080 still have power? | §5.3 depends on the sensor running while the ESP sleeps. |
| H3b | When GPIO 38 (shifter enable) is off, is the interrupt wire still connected to the ESP32? | GPIO 38 is off during sleep; the wake must still arrive. |
| H4 | Is the HDC2080's ADDR pin (pin 3) connected to ground or to VDD? | I2C address `0x40` or `0x41`. |
| H6 | Where does the sensor sit relative to the ESP32, the charger and the relay? Slots / no copper under it (datasheet §11)? | An AC unit's radio is always on; its heat offsets the reading and shapes the power-up guard. |
| H7 | Is the AC detector (`SIOT-SMOKE-AC-01`) the same PCB as the battery one? | One pin map or two. |

H5 is ours, not the designer's: the button wakes on low (`ESP_EXT1_WAKEUP_ANY_LOW`). Whether the
ESP32-S3 can mix a low-wake pin and a high-wake pin must be read in the ESP-IDF v5.5.2 headers before
choosing `INT_POL`; if it cannot, the sensor is set active-low, which the chip supports.

To fix in the spec when answered: the HDC2080 and ADPD188BI tables in `definition-detector.md` list
the **sensor's own pin numbers** under a column titled "GPIO" (HDC2080 pin 1 = SDA, 6 = SCL,
4 = DRDY/INT matches the datasheet), which reads as ESP GPIOs. The ESP side is GPIO 1 / 2 / 4.

### 11.1.1 Answers received (2026-11-26)

| # | Answer | What it means |
|---|---|---|
| H1 | **The two interrupt outputs are connected directly**, no component between them. | The conflict of H1 is now the expected behaviour of the final board, not a possibility — see below. |
| H1 (was it considered?) | No answer yet. | Still owed. |
| H2 | "Yes" — to a question that offered two alternatives (through a level converter / arrives at 1.8 V). | **Ambiguous.** Read as "it passes through a converter", which fits the earlier statement that a shifter exists — but the PCA9306 has only two channels (SDA, SCL), and H3b says the wire stays connected with GPIO 38 off, so it would have to be a separate converter. To be asked again as a single yes/no: "is there a level converter on the interrupt wire, separate from the PCA9306?" |
| H3 | **Yes**, the HDC2080 stays powered while the ESP32 sleeps. | §5.3 holds. |
| H3b | **Yes**, the interrupt wire stays connected to the ESP32 with GPIO 38 off. | The wake can arrive during sleep. |
| H4 | "Yes" — to "ground or VDD". | No answer, and none needed: **the driver probes both addresses at boot** (`0x40`, then `0x41`) and takes the one that returns the HDC2080 identity (`0x4954` / `0x07D0`). |

**What the direct connection (H1) means.** The HDC2080 pin drives the wire at all times once enabled:

- set **active-low**, it holds the wire high while idle — the smoke sensor pulling low fights it, and
  the smoke wake may not reach the ESP32;
- set **active-high**, it holds the wire low while idle — which is what the smoke sensor's "interrupt"
  looks like, permanently.

Neither polarity is safe on a shared wire. What can be done:

| Option | Change | Effect |
|---|---|---|
| A — give the HDC2080 its own ESP32 pin (recommended) | PCB: route HDC2080 pin 4 to **GPIO 8**, which the spec lists as "reserved for future use" and which is a wake-capable pin on the ESP32-S3 (RTC pins are GPIO 0–21, phase 2 brief §3) | The design of §5.3 as written; the ESP32 also knows which sensor woke it. |
| B — a component between the outputs | PCB: a diode or an open-drain buffer on the HDC2080 output | §5.3 as written; one wake pin for both sensors, the firmware asks each sensor which one it was. |
| C — firmware only, no PCB change | The HDC2080 pin is left disabled (floating, 0x0E bit 2 = 0), so it cannot fight the smoke sensor | **The battery unit cannot be woken by heat.** It measures at its timer wake only: a fire is noticed up to 60 s late and the rate-of-rise rule has one sample per minute — unless the wake interval is shortened, which costs battery. The AC unit is unaffected. |

Until the designer answers, **the firmware is written so the HDC2080 interrupt pin and its GPIO are
build settings**, with option C (pin disabled, timer-only measurement on the battery unit) available
as a mode. The development unit has only the HDC2080 on the wire, so steps 4 and 5 run as planned
there; what the final board does is decided by which option the designer takes.

### 11.2 For the product owner **[open]**

| # | Question | Blocks |
|---|---|---|
| O1 | Which standard and class is the product certified to? | nothing now; it may change numbers in §4, not structure |
| O2 | Confirm §3.2 (two heat codes, no pre-alarm, humidity in the heartbeat, fixed thresholds, no rise amount on the wire) | step 3 |
| O3 | Rate-of-rise guards: the 120 s power-up guard, and whether a floor temperature is wanted (a cold room being heated rises fast and is not a fire; a floor can also hide a real one) | step 4 tuning |

## 12. Not in this phase

The ADPD188BI smoke sensor; the heater; humidity-compensated smoke readings; dew-point calculation;
thresholds per installation; a heat pre-alarm.

## 13. Open risks

1. **H1 may need a PCB change.** §5.3 assumes GPIO 4 can carry the HDC2080's interrupt.
2. **Sensor-wake confirmation costs battery.** Each false wake is up to 60 s awake. A kitchen or a
   sunlit wall could wake a unit often; the +4 °C margin and the guards (O3) are the controls, and
   the wake count is reported so the bench can see it.
3. **The enclosure's thermal lag is unknown.** The sensor measures the PCB's air, not the room's.
   Both rules will respond later than the numbers suggest; only a test in the real housing tells by
   how much, and certification (O1) is measured there.
4. **Threshold comparison inside the chip** is 8-bit against a 14-bit reading; whether "over" means
   strictly above the code is not stated **[bench]**. Harmless, since the firmware decides, but it
   shifts the wake point by up to one step.
5. **Humidity near saturation ages the element** (§2.1); a unit that lives at 95 %+ will drift, and
   the 99.7 % rule will drift with it.
6. **One sensor unit.** Steps 4 and 5 share it; a regression on the AC side cannot be re-checked
   while it is flashed as a battery unit. The mock ramp (step 2) is what keeps both families
   testable at once.

## 14. Status — 2026-11-26, end of the first implementation session

Nothing below has run on a unit yet: it compiles and the rules pass their tests on the computer.

| Step | State |
|---|---|
| 0 Protocol | **Written**: revision 3.16 (`docs/safr/protocol-safr-v3.md` §7.1.2 codes `0x0D` `HEAT_RISE_ALARM` and `0x0E` `SENSOR_WET`, §7.1.5 bit5, §7.1.6 the rules, §7.3 `HUMIDITY` at offset 23). §3.2 was taken as agreed. |
| 1 Rules | **Done, host-tested**: `firmware/components/features/siot_sensing` (`siot_sensing_rules.h`, `sensing_rules.c`), 19 tests in `firmware/test/host/main/test_sensing.c`; the whole host suite: 103 tests, 0 failures. |
| 2 Mock on devkits | **Built for the AC unit, not flashed**: `firmware/build.sh node --mock 1\|2\|3` → `apps/node/build-mock<N>` (1 = slow heat to 60 °C, the fixed alarm; 2 = +10 °C in 40 s, the rate-of-rise alarm; 3 = 100 % humidity, sensor molhado; each starts 180 s after boot). Listed as relaxed for the bench: `docs/ota/before-production.md` item 13. The battery unit has no mock scenario wired to the rules yet (see below). |
| 3 App | See the app's own notes in `docs/others/app-sempreiot-central.md` and reference §3.6.1. |
| 4 Real sensor, AC unit | **Written and built, never run on the sensor**: the HDC2080 driver (`components/platform/siot_sensor/src/hdc2080.c`), the 1 s sampling task (`siot_sensing.c`), `siot_netcore_set_env_hook` / `siot_netcore_raise_event`, the pins in `tools/pinmap/pinmap.yaml` for `SIOT-SMOKE-AC-01`, `SIOT-SMOKE-01`, `SIOT-HEAT-01` (SDA 1, SCL 2, enable 38, interrupt 4). The node image has the feature on and reports nothing on a model without the sensor bus. DTR test part A: `CONFIG_SIOT_SENSING_DTR_TEST=y`. |
| 5 Battery unit | **Not started**, apart from its heartbeat now carrying `HUMIDITY` (24 bytes). Blocked by the finding below. |
| 6 Docs, presentation page | Not started. |

**Closed.** H5: the ESP32-S3 has one ext1 wake level for all its pins (`SOC_PM_SUPPORT_EXT1_WAKEUP_MODE_PER_PIN`
is not defined for it in ESP-IDF v5.5.2), and the button wakes on low — so the sensor's interrupt is
**active low** (`INT_POL = 0`). H4: the driver tries `0x40` then `0x41` and takes the one that
identifies as an HDC2080.

**Found: the battery unit has no alarm behaviour yet.** Protocol §12.6 tier 2–3 (stay awake until the
board's ACK, re-announce every 60 s, the broadcast fallback, RESET / SILENCE) was never written in
`siot_leafcore` — its command handler says "alarm/relay behaviour is the next increment", and the
only event a battery unit sends today is the walk test. A heat alarm on a battery unit needs that
path first. Step 5 is therefore two pieces: (a) the leaf alarm path, (b) the sensor wake, the moving
threshold and the RTC history. The AC unit has all of it already.

**To check on the first run with the sensor** (the datasheet does not settle them): that writing
`MEAS_TRIG` once after setting the auto mode starts the 1 Hz conversions; the idle level of the
interrupt pin; whether "over the threshold" is strict.

**Known limit on the AC unit.** netcore tracks one frame for its fast retry: an alarm takes the
slot, a trouble only a free one — it still asks for the central's ACK, but is not re-sent if that
ACK never comes.
