# SAFR v3 — Secure Alarm Frame Relay

**Serial protocol between the mesh ROOT node and the Central (tablet app).**

This document is the **single source of truth** for the SAFR v3 protocol. Both the
firmware (`mocked-device/`, later the real esp-mesh-lite firmware) and the Flutter
central app (`mobile/sempreiot_central_app/`) implement exactly what is written
here. Do **not** keep divergent layout comments in code — cite this file instead.

- Version: **3** (`VER = 0x03`). Revision **3.2** (2026-09-24) adds the installation-lifecycle
  messages (§7.6 CMD 0x11–0x19, §7.12–§7.15, ACK `DETAIL`) — all additive, `VER` unchanged; the
  flows are in `docs/others/installation-lifecycle-v1.md`.
- Status: implemented (uplink + downlink + journal backfill); v3.2 additions: specified, Phase 2
- Supersedes: SAFR v2 (`VER = 0x02` — decode-only for stored packets) and
  SAFR v1 (`VER = 0x01` — deprecated, decode-only)

---

## 0. Compliance framework (normative)

SAFR v3 is designed so that a system built on it can be certified against the
fire-detection standards below. Every rule in this spec that exists **because of
a standard** is tagged inline with a `⛑` note naming the standard. These four
are permanent constraints on this project — any protocol or feature change must
be checked against them:

| Standard | Scope | What it imposes on SAFR |
|----------|-------|--------------------------|
| **UL 864** (10th ed.) | Control units and accessories for fire alarm systems (US listing) | Alarm priority over all other traffic; alarm latching until manual reset; monitoring for integrity of every communication path; distinct trouble annunciation; cybersecurity expectations (UL 2900 family). |
| **NFPA 72** (National Fire Alarm and Signaling Code, US) | Installation/performance code; §23.16 covers low-power wireless systems | Alarm delivery ≤ 10 s; loss of communication with any single device annunciated ≤ **200 s**; alarm signals repeated at intervals ≤ **60 s** until the initiating device restores; low-battery trouble identifying the specific device, with ≥ 7 days of operation remaining; alarm latching until manual reset. |
| **EN 54-25** | Fire detection components using radio links (EU) | First alarm indicated ≤ 10 s, last alarm ≤ 100 s, **no alarm message lost** (⇒ buffering + backfill); transmission-path fault signaled ≤ **300 s**, verified in **both directions**; site-specific identification (neighboring systems must be mutually incompatible); battery fault warning well before exhaustion (≈ 30 days). |
| **ISO 7240-25** | International mirror of EN 54-25 | Same requirements as EN 54-25. |

> **Architectural note (read this before extending the system):** UL 864 / EN 54-2
> require the *control unit* to be certified hardware with supervised redundant
> power and a hardware watchdog. A consumer tablet cannot be that. The intended
> certification path is: the **ROOT (or a dedicated panel board) is the control
> unit** and owns the safety logic — latching, supervision, the event journal —
> while the tablet app is a **supplementary annunciator/operator interface**.
> Every mandatory behavior in this spec is therefore written to be enforceable
> on the root even with the central disconnected. Today the app also implements
> the panel-side rules (latching, supervision) so the protocol can be validated
> end-to-end on the bench.

> **Editions caveat:** numeric limits quoted here (200 s, 300 s, 60 s, 10 s,
> 7/30 days) are from secondary sources. Before submitting to a test lab,
> verify clause numbers and values against the purchased current editions.

### Severity priority

`ALARM (3) > ALERT/supervisory (2) > TROUBLE (1) > OK/restore (0)`

⛑ **UL 864 / NFPA 72 §10.6:** alarm signals take precedence over supervisory,
supervisory over trouble. Consequences in this spec:

- Every transmitter (device, root, central) must give ALARM frames **absolute
  priority** in its TX queue — an ALARM frame preempts queued HEARTBEAT /
  TOPOLOGY / EVENT_LOG_DATA frames.
- The central renders/processes higher severities first.
- End-to-end latency budget for an ALARM: **≤ 10 s** from detector activation
  to display at the central (mesh hops + serial). ⛑ NFPA 72 / EN 54-25.

---

## 1. System model

```
[leaf]──┐
[leaf]──┤ esp-mesh-lite (Wi-Fi)          UART 115200 8N1           Flutter app
[leaf]──┼──> [node/relay] ──> [ROOT] <═══════════════════> [CENTRAL (tablet)]
[leaf]──┘                       │        binary SAFR v3
                             mains 24h + event journal
```

| Role | Power | Behavior |
|------|-------|----------|
| **CENTRAL** | tablet | Receives everything; ACKs critical uplink; sends COMMAND / TIME_SYNC / EVENT_LOG_REQ downlink; latches alarms until operator RESET. Reserved MAC `00:00:00:00:00:01`. |
| **ROOT** | mains, 24 h | The *active confirmer* and the future certified control unit. Bridges mesh⇄serial. ACKs central downlink, retries critical uplink, **persists every event in the journal (§8)** and replays it on request. |
| **NODE (relay)** | mains/battery | Forwards upstream traffic, emits own events/heartbeats/topology. |
| **LEAF** | battery | Passive: wake → measure → send → sleep. Never ACKs, never relays. Must stay awake while it has an active ALARM (§7.2). |

The protocol is **event-oriented**: devices push EVENTs when something changes,
HEARTBEATs prove liveness (supervision), TOPOLOGY describes the mesh shape,
and the journal guarantees no event is ever lost to a link outage.

---

## 2. Transport

- UART **115200 baud, 8N1**, raw binary. Firmware uses the UART **driver**
  (`uart_write_bytes` / RX ring buffer) — **never** stdout/console VFS, which
  translates `0x0A → 0x0D 0x0A` and corrupts frames (the SAFR v1 bug).
- Firmware builds with `CONFIG_ESP_CONSOLE_NONE=y` so no log text pollutes the link.
- ESP32 boot-ROM chatter after reset is unavoidable; receivers must resync using
  SOF + LEN + CRC (§5): on any validation failure, discard **one** byte and rescan.

⛑ **UL 864 (monitoring for integrity):** the serial path is supervised in
**both directions** (§9). An open port with no valid traffic is *not* a working
link.

---

## 3. Frame layout

All multi-byte integers are **big-endian**. One frame per message; no inter-frame
delimiter other than SOF + LEN + CRC validation.

```
Offset  Size  Field      Description
------  ----  ---------  ----------------------------------------------------------
0       1     SOF        0xA5
1       1     VER        0x03
2       2     LEN        Total frame length in bytes, SOF through CRC inclusive
4       1     MSG_TYPE   §7
5       2     MSG_ID     Per-sender sequence number; echoed by ACK
7       2     SYSTEM_ID  Installation (site) identity — §3.1
9       6     SRC_MAC    Sender MAC (central = 00:00:00:00:00:01)
15      6     DST_MAC    FF:FF:FF:FF:FF:FF = broadcast / "to central"
21      1     TTL        Initial 7 − layer; decremented per hop
22      1     HOPS       Hops travelled so far (== layer at origin)
23      1     FLAGS      §3.2
24      2     BOOT_CTR   Nonce component; ++ every device boot (NVS-persisted)
26      4     MSG_CTR    Nonce component; ++ every frame sent by this sender
------  ----  ---------  ---- header = 30 bytes = AAD (bytes 0..29) ----
30      N     PAYLOAD    Ciphertext if F_ENC, plaintext otherwise (§7)
30+N    16    TAG        AES-CCM tag — present ONLY if F_ENC
last-2  2     CRC16      Over bytes 0 .. LEN-3 (everything except the CRC itself)
```

Frame sizes: `LEN = 30 + N + (F_ENC ? 16 : 0) + 2`.
Receivers must reject `LEN < 34` or `LEN > 250`.
*(v3.1, 2026-09-22: cap lowered from 256 to 250 — the ESP-NOW payload limit — so every frame that is legal on
the serial/mesh hops is also legal on the battery-detector hop. Max payload = 250 − 30 − 16 − 2 = 202 bytes;
no existing message type comes close — worst case is INSTALLATION with two max-length entries ≈ 182 bytes.)*

### Field-by-field description (header)

| Field | What it is for |
|-------|----------------|
| **SOF** (`0xA5`) | Start-of-frame marker. The only job of this byte is resynchronization: after line noise or ESP32 boot chatter, the receiver scans for `0xA5` and validates the candidate with LEN + CRC. `0xA5` = `1010 0101`, an alternating bit pattern unlikely in ASCII debug text. |
| **VER** (`0x03`) | Protocol version. Lets one receiver speak to mixed firmware during upgrades: v3 is encode+decode, v2/v1 are decode-only (for packets stored in the DB before the upgrade). Unknown versions are rejected with a "bad version" diagnostic, never guessed at. |
| **LEN** | Total frame length including SOF and CRC. Combined with SOF+CRC it makes framing self-describing — the receiver knows exactly how many bytes to wait for and where the CRC lives. Bounds (34..250) reject absurd values early so a corrupted LEN can't stall the reframer. |
| **MSG_TYPE** | Selects the payload layout (§7). Payloads are fixed-layout per type (not TLV): constant offsets are simpler in C, trivially testable, and auditable line-by-line by a certification lab. |
| **MSG_ID** | Per-sender 16-bit sequence number. Two jobs: (a) ACK correlation — an ACK names the MSG_ID it confirms; (b) duplicate detection for fast retransmissions (§9.1), which reuse the MSG_ID so the receiver processes once but ACKs every time. |
| **SYSTEM_ID** | Site identity (§3.1). ⛑ EN 54-25: components of one installation must not be compatible with a neighboring installation. |
| **SRC_MAC** | Unique identity of the originating device. ⛑ NFPA 72: every signal (alarm, trouble, low battery) must identify the *specific* device. Also one of the three CCM nonce components (§4). The central uses the reserved MAC `00:00:00:00:00:01`. |
| **DST_MAC** | Routing target. `FF:FF:FF:FF:FF:FF` means "broadcast" uplink (to the central) or "all devices" downlink. Relays forward frames without needing the key because the header is authenticated but not encrypted. |
| **TTL** | Hop budget (initial `7 − layer`, decremented per hop). Kills routing loops in the mesh: a frame that circulates is discarded when TTL hits 0 instead of flooding the network forever. |
| **HOPS** | Hops travelled so far (= mesh layer at origin). Diagnostic: lets the central display how deep in the mesh a device sits and correlate delivery latency with depth. |
| **FLAGS** | Frame semantics bits (§3.2). |
| **BOOT_CTR** | Reboot counter, persisted in device NVS, incremented every boot. Half of the replay/nonce-freshness story: it guarantees nonce uniqueness across reboots even though MSG_CTR restarts at 0. |
| **MSG_CTR** | 32-bit per-sender frame counter, reset each boot. The other half of the nonce; also drives replay rejection (§4). Retransmissions ALWAYS use a fresh MSG_CTR — a CCM nonce is never reused, even for identical plaintext. |

### 3.1 SYSTEM_ID — site-specific identification

⛑ **EN 54-25 / ISO 7240-25** require that components of one installation are
not interoperable with a neighboring installation. Two mechanisms enforce this:

1. **The per-installation PSK (§4)** — a frame from a foreign site fails CCM
   authentication because the key differs. This is the *security* boundary.
2. **SYSTEM_ID** — a 16-bit installation identity assigned at provisioning,
   carried in clear (but authenticated, since the header is AAD). This is the
   *diagnostic* boundary: it lets the central distinguish **"neighboring
   system"** (SYSTEM_ID ≠ ours → log "sistema vizinho", ignore) from
   **"our device with a wrong key"** (SYSTEM_ID = ours, TAG fails → raise a
   key-mismatch trouble). Without it, both conditions look like "auth failed".

- Development/mock value: **`0x5346`** (ASCII "SF").
- `0x0000` is reserved for *unprovisioned* equipment and must never appear in
  a production installation **on the mesh**. *(v3.2)* On the **USB link only**
  it identifies the **setup channel**: frames keyed with
  `HKDF-SHA256(ikm = utf8(pop), salt = utf8(id), info = "siot-setinst-v1", L = 16)`
  of the board's own sticker. A board in SETUP (no code) accepts only
  `COMMAND SET_INSTALLATION` and `LINK_CHECK` on it; a provisioned board accepts
  only `COMMAND GET_CODE` on it (§7.6). A node never accepts SYSTEM_ID 0x0000.
- Receivers drop frames whose SYSTEM_ID differs from their own **before**
  attempting decryption, and count them separately (`foreign` diagnostic).

### 3.2 FLAGS

| Bit | Name | Meaning |
|-----|------|---------|
| 0 | **F_ENC** | Payload is encrypted (AES-CCM) and a 16-byte TAG follows it. **Production receivers must reject frames without F_ENC** (§4.1) — plaintext is a bench-debug facility only. |
| 1 | **F_ACK_REQ** | Sender demands an ACK (§9). Set on ALARM/TROUBLE events and on all central downlink except EVENT_LOG_REQ. |
| 2 | **F_RETX** | This frame is a **periodic re-announcement** of a condition already reported (§7.2): same DEV_SEQ, fresh MSG_ID/MSG_CTR. Lets the log console label repeats honestly instead of showing what looks like a brand-new alarm every 60 s. ⛑ NFPA 72 §23.16: alarm repeated ≤ every 60 s until restore. |
| 3–7 | reserved | Must be 0. Receivers ignore them (forward compatibility). |

### 3.3 Why a whole-frame CRC *and* an AEAD tag?

They answer different questions, and the distinction drives the UI diagnostics:

| Check | Fails when | Human meaning |
|---|---|---|
| CRC16 | bytes were mangled on the wire (noise, bad cable, LF-translation class of bugs) | "Quadro corrompido na transmissão" |
| CCM TAG | bytes arrived intact but keys/nonce/AAD don't match | "Falha de autenticação — verifique a chave (PSK)" |

The CRC also gives plaintext debug frames (F_ENC = 0) integrity.

---

## 4. Cryptography

- **Cipher:** AES-128-CCM (mbedTLS `mbedtls_ccm_encrypt_and_tag` / PointyCastle
  `CCMBlockCipher(AESEngine())`).
- **Tag:** 16 bytes.
- **Nonce (12 bytes):** `SRC_MAC(6) ‖ BOOT_CTR(2) ‖ MSG_CTR(4)` — header bytes
  9..14 ‖ 24..29 — so nothing extra travels on the wire and the nonce is unique
  as long as `(BOOT_CTR, MSG_CTR)` never repeats per device. Real hardware
  persists BOOT_CTR in NVS and increments on every boot; the mock randomizes it
  at boot. MSG_CTR is a 32-bit per-sender counter reset each boot.
- **AAD:** the full 30-byte header (bytes 0..29). The header is authenticated
  but not encrypted, so relays can route — and receivers can check SYSTEM_ID —
  without the key.
- **Key (PSK, development only):**

  ```
  25 11 8B A1 DD 19 B8 45 09 DF 36 E9 41 6B 8D BE
  ```

  ⚠ DEV KEY. **Per-installation key provisioning is a production launch
  prerequisite, not future work** (⛑ EN 54-25 site separation; UL 864 10th ed.
  cybersecurity). The provisioning wizard (SoftAP flow) must inject a unique
  PSK + SYSTEM_ID into every device of an installation. Never ship this key.

- **Replay protection:** the central stores the last seen `(BOOT_CTR, MSG_CTR)`
  per SRC_MAC. A frame with a lower or equal counter pair from the same boot
  must be treated as a replay (log diagnostic, do not update device state).

### 4.1 Plaintext frames are rejected in production

⛑ **UL 864 (10th ed., cybersecurity) / EN 54-25:** state changes at the control
unit must not be triggerable by unauthenticated messages. Therefore:

- `F_ENC = 0` frames are accepted **only** when the receiver runs in explicit
  development mode (`kSafrAllowPlaintext` in the app; absent from production
  firmware).
- In production mode a plaintext frame produces a diagnostic feed entry
  (`plaintext_rejected`) and is otherwise ignored — it never updates device
  state and is never ACKed.

---

## 5. CRC-16 (CRC-16/CCITT-FALSE)

Polynomial `0x1021`, init `0xFFFF`, no reflection, no final XOR.
Check value: `crc16("123456789") == 0x29B1`.

C reference:

```c
uint16_t safr_crc16(const uint8_t *data, size_t len) {
    uint16_t crc = 0xFFFF;
    for (size_t i = 0; i < len; i++) {
        crc ^= (uint16_t)data[i] << 8;
        for (int b = 0; b < 8; b++)
            crc = (crc & 0x8000) ? (crc << 1) ^ 0x1021 : (crc << 1);
    }
    return crc;
}
```

Dart reference: `lib/features/central/domain/safr/crc16.dart` (same algorithm).

---

## 6. Event identity: DEV_SEQ

Every device keeps a persistent 16-bit **event sequence number** (`DEV_SEQ`),
incremented for every *distinct* event it originates (NVS-persisted on real
hardware, like BOOT_CTR). It travels in the EVENT payload (§7.1) and is the
**identity of the event**, distinct from the identity of the frame (MSG_ID):

| Counter | Identifies | Fresh on retransmit? |
|---------|-----------|----------------------|
| MSG_CTR | the *frame on the wire* (nonce) | always fresh |
| MSG_ID | the *transmission attempt group* (ACK correlation) | reused on fast retry (§9.1), fresh on 60 s re-announce |
| DEV_SEQ | the *event itself* | **never changes** for the same event |

Consequences:

- The central dedupes events by `(SRC_MAC, DEV_SEQ)` — a 60 s alarm
  re-announcement (F_RETX) updates "last heard" but does not create a second
  feed entry or a second siren trigger.
- Journal replay (§8) can deliver an event the central already saw live; the
  same dedupe silently absorbs it. **This is what makes "no alarm lost" (⛑
  EN 54-25) implementable without double-alarming.**
- A gap in DEV_SEQ tells the central events were missed → request backfill.

DEV_SEQ wraps at 0xFFFF → 1 (`0x0000` is reserved for "no sequence", used by
v2-decoded events).

---

## 7. Message types & payload layouts

Payloads are **fixed-layout per message type** (not TLV): constant offsets are
simpler to implement in C, trivially testable, and auditable for certification.

Sentinels for "not available": `0xFF` (uint8), `0xFFFF` (uint16), `0x7FFF` (int16).

| MSG_TYPE | Name | Direction | Payload |
|----------|------|-----------|---------|
| 0x01 | EVENT | uplink | 17 bytes |
| 0x02 | HEARTBEAT | uplink; the board's own copy also downlink (§7.3) | 20 bytes |
| 0x03 | TOPOLOGY | uplink | 14 + 7·children |
| 0x04 | ACK | both | 4 bytes |
| 0x05 | COMMAND | downlink | 2 + n bytes |
| 0x06 | TIME_SYNC | downlink | 5 bytes |
| 0x07 | EVENT_LOG_REQ | downlink | 5 bytes |
| 0x08 | EVENT_LOG_DATA | uplink | 28 bytes |
| 0x09 | INSTALLATION | uplink (board → central) | variable, ≤ 202 bytes |
| 0x0A | NAME_ANNOUNCE | uplink | variable, ≤ 51 bytes (v3.2: optional ROLE byte) |
| 0x0B | DEVICE_TABLE *(v3.2)* | uplink (board → central, serial only) | variable, ≤ 202 bytes, paged |
| 0x0C | CODE *(v3.2)* | uplink (board → central, setup channel only) | variable, ≤ 90 bytes |
| 0x0D | PARENT_PROBE *(v3.2)* | ESP-NOW broadcast (leaf or surveying unit → neighbours) | 1 byte |
| 0x0E | PARENT_OFFER *(v3.2)* | ESP-NOW unicast (neighbour → prober) | 3 bytes |

### 7.1 EVENT — `MSG_TYPE 0x01` (uplink) — payload 17 bytes

The core message: something changed at a device.

| Off | Size | Field | What it is for |
|----|------|-------------|-------|
| 0 | 1 | EVENT_TYPE | Severity class (§7.1.1). Drives priority, latching, and the color/sound at the central. |
| 1 | 1 | EVENT_CODE | *What happened* (§7.1.2) — the specific condition within the severity class. |
| 2 | 4 | TIMESTAMP | Unix epoch seconds at the device when the condition was detected (real wall-clock after TIME_SYNC). Kept even though the central also timestamps reception: for a buffered/replayed event the two differ, and the *detection* time is the one that matters for the mandatory event history. |
| 6 | 1 | PWR_FLAGS | Power/tamper snapshot (§7.1.3), mapped 1:1 to device GPIOs. |
| 7 | 1 | BATTERY_PCT | 0–100, 0xFF = n/a. Display/registry value; the *normative* battery signaling is via BATT_LOW/BATT_CRITICAL events (§7.1.4). |
| 8 | 2 | SMOKE | Raw ADU from the ADP188BI smoke sensor, 0xFFFF = n/a. Raw (not a boolean) so the central can show pre-alarm trends and the lab can verify thresholds. |
| 10 | 2 | TEMP | int16, °C × 10, 0x7FFF = n/a. |
| 12 | 1 | HUMIDITY | %, 0xFF = n/a. |
| 13 | 1 | FAULT_FLAGS | Bitmask of *all* currently active faults (§7.1.5) — a device can have several at once. |
| 14 | 1 | FAULT_CODE | The *primary* fault (0 = none). For RESTORE events this carries the code of the condition that cleared. |
| 15 | 2 | **DEV_SEQ** | Event identity (§6). |

**ALARM and TROUBLE events must set `F_ACK_REQ`.**

#### 7.1.1 EVENT_TYPE

| Value | Name | Severity | Latching at the central |
|-------|---------|---|---|
| 0x01 | OK / RESTORE | 0 | n/a — clears troubles/supervisory (§7.1.4), **never clears a latched ALARM** |
| 0x02 | ALERT (supervisory — pre-alarm) | 2 | not latched |
| 0x03 | ALARM | 3 | **latched until operator RESET** (§7.4) ⛑ UL 864 / NFPA 72 |
| 0x04 | TROUBLE | 1 | cleared by matching RESTORE; root/repeater AC-loss latches until power actually returns ⛑ NFPA 72 §23.16 |

#### 7.1.2 EVENT_CODE

| Value | Name | Typical EVENT_TYPE | Notes |
|-------|------|--------------------|-------|
| 0x00 | NONE / periodic status | OK | |
| 0x01 | SMOKE_ALARM | ALARM | |
| 0x02 | HEAT_ALARM | ALARM | |
| 0x03 | SMOKE_RISING (pre-alarm) | ALERT | |
| 0x04 | MANUAL_TEST (GPIO21 short press) | ALERT | distinct from a real alarm ⛑ NFPA 72 test signals |
| 0x05 | TAMPER (GPIO11 — removed from base) | TROUBLE | |
| 0x06 | BATT_LOW | TROUBLE | threshold = **≥ 7 days of operation remaining** (⛑ NFPA 72), targeting ~30 days warning (⛑ EN 54-25) — a runtime guarantee, not a raw % |
| 0x07 | BATT_CRITICAL | TROUBLE | imminent shutdown |
| 0x08 | SENSOR_FAULT | TROUBLE | |
| 0x09 | COMM_FAULT (child unreachable, reported by parent/root) | TROUBLE | |
| 0x0A | AC_LOST (on battery — GPIO6 BOOST) | TROUBLE | latches for root/repeaters ⛑ NFPA 72 §23.16 |
| 0x0B | RESTORE (condition cleared; pairs with prior code in FAULT_CODE) | OK | |
| 0x0C | **RF_INTERFERENCE** (RF path degraded/jammed) | TROUBLE | ⛑ EN 54-25: interference on the radio path must be detected and signaled |

#### 7.1.3 PWR_FLAGS (maps 1:1 to the device GPIOs)

| Bit | Name | GPIO | Meaning |
|-----|------------|------|---------|
| 0 | AC_OK | 5 (ACOK) | mains present |
| 1 | CHARGING | 7 (CHG) | battery charging |
| 2 | ON_BATTERY | 6 (BOOST) | running from battery |
| 3 | TAMPER | 11 (TAMPER) | removed from base |
| 4 | TEST_PRESSED| 21 (RST/TESTE) | test button held |
| 5-7 | reserved | | |

#### 7.1.4 Latching & restore semantics ⛑ UL 864 / NFPA 72

- An **ALARM** latches at the central the moment it is accepted. The latch is
  cleared **only** by an operator-initiated `RESET` command (§7.5) — never by
  a RESTORE event, never by a timeout, never by the device going silent.
  (A RESTORE after an alarm is still recorded in the feed — "detector voltou
  ao normal" — the *latch* is what persists.)
- A **TROUBLE** is cleared by the matching RESTORE (FAULT_CODE names the
  condition that cleared), except root/repeater AC-loss which is only cleared
  by a RESTORE reporting mains actually back.
- An **ALERT** (supervisory) is informational and does not latch.

#### 7.1.5 FAULT_FLAGS / FAULT_CODE

| Bit / Value | Name |
|------|------|
| bit0 / 1 | SMOKE_SENSOR (ADP188BI I2C failure) |
| bit1 / 2 | TEMP_SENSOR (HDC2080 failure) |
| bit2 / 3 | BATT_CRITICAL |
| bit3 / 4 | MESH_LOST |
| bit4 / 5 | RELAY_FAIL (GPIO12) |

### 7.2 Critical-event delivery ⛑ NFPA 72 §23.16 / EN 54-25

For EVENT frames with severity ALARM or TROUBLE:

1. **Fast phase:** send with `F_ACK_REQ`; if un-ACKed, retransmit up to
   **3 times with 2 s backoff** — same MSG_ID (receiver dedupes), fresh
   MSG_CTR. If still un-ACKed the sender raises its own local TROUBLE
   `COMM_FAULT` **and keeps going** — giving up is not permitted:
2. **Re-announcement phase (ALARM only):** while the alarm condition persists
   and no `RESET` was received, re-send the ALARM event **at least every
   60 s**: fresh MSG_ID + MSG_CTR, **same DEV_SEQ**, `F_RETX` set. The
   central ACKs each one; dedupe by DEV_SEQ prevents duplicate feed entries.
3. A **leaf in alarm must not sleep** — it stays awake, keeps its radio up and
   re-announces on schedule until restore or RESET.

The v2 behavior ("3 retries then give up") is **non-compliant and removed**.

### 7.3 HEARTBEAT — `MSG_TYPE 0x02` (uplink) — payload 20 bytes

Supervision beacon (§9.2). Never sets `F_ACK_REQ`; never inserted into the
Events feed — it silently updates the device registry (battery, RSSI, last-seen).

**The board's own HEARTBEAT goes both ways (v3.3, 2026-09-27).** The board sends
it to the central every 15 s as before *and* broadcasts the same frame down into
the mesh; every node relays it one hop further (dedupe §9.1 makes this
loop-safe). It is the one downlink frame a node hears on a fixed cadence with or
without a central attached, so a node that has joined the mesh takes it as proof
the board is behind the mesh (LED "online", §9.3 board-silence detection).
Before this a joined node waited for the central's LINK_CHECK (up to 30 s) or a
TEST tap, and with no central attached it waited forever. A node's own
HEARTBEAT is never relayed downward: uplink frames go root → central only.

| Off | Size | Field | What it is for |
|----|------|--------------------|---|
| 0 | 4 | TIMESTAMP (epoch s) | device clock check — drift shows here first |
| 4 | 4 | UPTIME_S | reboot detection / stability diagnostic |
| 8 | 1 | PWR_FLAGS (§7.1.3) | continuous power supervision without event spam |
| 9 | 1 | BATTERY_PCT | registry freshness |
| 10 | 2 | TEMP (int16 ×10) | ambient trend |
| 12 | 1 | RSSI_TO_PARENT (int8 dBm; root: 0x7F = n/a) | RF-link quality — feeds the RF_INTERFERENCE detection |
| 13 | 6 | PARENT_MAC (root: 00:00:00:00:00:01 = the central) | topology cross-check |
| 19 | 1 | LAYER (root = 0) | mesh depth |

### 7.4 TOPOLOGY — `MSG_TYPE 0x03` (uplink) — payload 14 + 7·CHILD_COUNT bytes

Sent by every non-leaf node (root included) every 60 s and on any child change.

| Off | Size | Field | What it is for |
|----|------|--------------------|---|
| 0 | 4 | TIMESTAMP | |
| 4 | 1 | NODE_ROLE (0 root, 1 node/relay, 2 leaf) | drives supervision interval selection (§9.2) |
| 5 | 1 | LAYER | |
| 6 | 6 | PARENT_MAC | mesh map edge |
| 12 | 1 | RSSI_TO_PARENT (int8) | |
| 13 | 1 | CHILD_COUNT (0–16) | |
| 14+7i | 6 | CHILD_MAC[i] | |
| 20+7i | 1 | CHILD_RSSI[i] (int8) | |

### 7.5 ACK — `MSG_TYPE 0x04` (both directions) — payload 4 bytes

| Off | Size | Field | What it is for |
|----|------|-------|---|
| 0 | 2 | ACKED_MSG_ID | which transmission is being confirmed |
| 2 | 1 | STATUS: 0x00 OK, 0x01 ERROR, 0x02 UNKNOWN_DST | OK = processed; ERROR = received but rejected; UNKNOWN_DST = no such device |
| 3 | 1 | DETAIL *(v3.2; was RESERVED, always 0 before)* | With STATUS ERROR on the v3.2 commands: `0x01` unknown MAC · `0x02` table full · `0x03` not retired · `0x04` bad ARGS · `0x05` refused (own MAC / broadcast) · `0x06` not in setup mode · `0x00` no detail. Pre-v3.2 receivers ignore the byte. |

`DST_MAC` = original sender; `SRC_MAC` = the confirmer. The **root** ACKs central
downlink on behalf of the mesh; the **central** ACKs any uplink frame carrying
`F_ACK_REQ`. ACK frames themselves never set `F_ACK_REQ`. The **board** ACKs
every downlink COMMAND itself before relaying it, and **forwards the central's
ACKs down** into the mesh so a node sees the tablet's confirmation of its
`F_ACK_REQ` uplinks (Phase 1 brief §14 item 4).

### 7.6 COMMAND — `MSG_TYPE 0x05` (downlink, central → root) — payload 2 + n bytes

Sets `F_ACK_REQ`. `DST_MAC` selects the target device (broadcast allowed).

| Off | Size | Field |
|----|------|-------|
| 0 | 1 | CMD |
| 1 | 1 | ARG_LEN (n) |
| 2 | n | ARGS |

| CMD | Name | ARGS | What it is for |
|-----|------|------|----------------|
| 0x00 | **LINK_CHECK** | — | Downlink path supervision (§9.3): a no-op the root simply ACKs. Proves central→root TX works. ⛑ UL 864 integrity monitoring / EN 54-25 bidirectional link verification. |
| 0x01 | SILENCE (relay/sounder off) | — | Silences sounders. **Does not clear the alarm latch** — silencing and resetting are distinct operator actions. ⛑ UL 864. |
| 0x02 | TEST (self-test request) | — | Requests a device self-test; produces a MANUAL_TEST ALERT, distinguishable from a real alarm. |
| 0x03 | RELAY_SET | 1 byte: 0/1 (GPIO12) | Output control. |
| 0x04 | IDENTIFY (blink RGB) | 1 byte: seconds | Physically locate a device during commissioning. |
| 0x05 | **RESET** | — | Operator alarm reset (§7.1.4): device leaves alarm state (if the sensed condition has cleared), stops re-announcing, and the central clears its latch **after the root ACKs**. Broadcast = system reset. ⛑ UL 864 / NFPA 72: alarms clear only by manual reset. |
| 0x10 | GET_INSTALLATION *(v3.1, POC round 1 — pocs/POC-BRIEF.md §4.2)* | — | Sent by the central to the board over the serial link only (never relayed into the mesh). The board replies with INSTALLATION (§7.10). |
| 0x11 | SET_INSTALLATION *(v3.2, Case B)* | `system_id u16 ‖ channel u8 ‖ mesh_id u8 ‖ ssid_len u8 ‖ ssid (≤ 31) ‖ psk_len u8 ‖ psk (≤ 31) ‖ safr_psk[16] ‖ name_len u8 ‖ name (≤ 32)` | Tablet writes the code into a board that has none (blueprint §3.2 B1). **Setup channel only** (§3.1: header SYSTEM_ID `0x0000`, pop-derived key, `SRC_MAC` = central, `DST_MAC` = board). The board validates (`system_id ≠ 0`, `channel ∈ {1,6,11}`, lengths), stores the code, ACKs OK and reboots ≈ 1 s later. A provisioned board answers ERROR/`DETAIL 0x06`. Never relayed. |
| 0x12 | SET_DEVICE *(v3.2)* | `mac[6] ‖ name_len u8 ‖ name (≤ 32) ‖ zone_len u8 ‖ zone (≤ 16)` | Rename / re-zone a unit (lifecycle §5 H). The board updates its device table (`ANNOTATED`; `PENDING_RENAME` if the unit is not online), ACKs at once, then relays with `DST_MAC = mac`. The unit stores name/zone in NVS, ACKs, and sends `NAME_ANNOUNCE`. Unknown MAC → the board creates an `expected` entry. |
| 0x13 | RETIRE_DEVICE *(v3.2)* | `mac[6]` | Board-only (serial, never relayed): entry → `retired`; the board drops that MAC's frames from now on (lifecycle §3.2). ERROR/`0x01` unknown MAC. |
| 0x14 | UNRETIRE_DEVICE *(v3.2)* | `mac[6]` | Board-only: `retired` → `expected` (never heard) or `missing` (heard before); clears `HEARD_WHILE_RETIRED`. ERROR/`0x03` if not retired. |
| 0x15 | REPLACE_DEVICE *(v3.2)* | `old_mac[6] ‖ new_mac[6]` | Board-only: copies name/zone from old to new (`ANNOTATED` + `PENDING_RENAME` on new), retires old, and — if old is `online` — originates a `DECOMMISSION` to it. ERROR/`0x01` if old unknown; `0x05` if either MAC is the board's or broadcast. |
| 0x16 | DECOMMISSION *(v3.2)* | `mac[6]` | Remote factory reset. `DST_MAC` **must equal** `ARGS.mac` and must not be broadcast; the board refuses otherwise (`0x05`) and refuses its own MAC. The board marks the entry `retired` (`PENDING_DECOMMISSION` if not online), ACKs, relays. The node accepts only if `DST_MAC == own MAC == ARGS.mac`: it ACKs, waits ≈ 300 ms, erases `siot_inst`, and reboots into setup mode (white blink). Leafs: delivered through the parent mailbox when it exists (lifecycle §5.2). |
| 0x17 | FORGET_DEVICE *(v3.2)* | `mac[6]` | Board-only: deletes a `retired` entry. ERROR/`0x03` if not retired, `0x01` unknown. |
| 0x18 | GET_DEVICE_TABLE *(v3.2)* | `page u8` (`0` = all pages) | Board-only: the board answers with one `DEVICE_TABLE` frame per page (§7.12). Sent by the tablet on link-up after `GET_INSTALLATION`, and on "Ressincronizar". |
| 0x19 | GET_CODE *(v3.2)* | — | **Setup channel only**, accepted by a **provisioned** board: the tablet proves the board's `pop` (the operator typed or scanned the board sticker; the key is derived from it) and the board answers `CODE` (§7.13). This is how a tablet — camera or not — gets the code after the board was provisioned from a phone, and the only way the code ever leaves the board over USB (blueprint rule 5, lifecycle §4.1). |

### 7.7 TIME_SYNC — `MSG_TYPE 0x06` (downlink, central → root) — payload 5 bytes

Sent by the central on link-up and every hour. The root adopts the epoch and
re-distributes it into the mesh; device timestamps become real wall-clock time —
which is what makes the journal's detection timestamps (§8) meaningful in the
mandatory event history.

| Off | Size | Field |
|----|------|-------|
| 0 | 4 | EPOCH (Unix seconds, UTC) |
| 4 | 1 | TZ_OFFSET_QH (int8, quarter-hours from UTC; display hint only) |

### 7.8 EVENT_LOG_REQ — `MSG_TYPE 0x07` (downlink, central → root) — payload 5 bytes

Backfill request: "give me every journaled event after JRN_SEQ N".
Sent on every link-up (after TIME_SYNC), and whenever the central suspects a
gap. Does not set `F_ACK_REQ` — the EVENT_LOG_DATA response *is* the
confirmation; if none arrives in 5 s the central re-requests (3×), then raises
a link TROUBLE.

| Off | Size | Field | What it is for |
|----|------|-------|---|
| 0 | 4 | SINCE_JRN_SEQ | last journal sequence the central has (0 = everything the root still holds) |
| 4 | 1 | MAX_COUNT | cap on replayed entries per request (0 = root's default batch, 32) — flow control so a long outage doesn't flood the UART ahead of live alarms |

### 7.9 EVENT_LOG_DATA — `MSG_TYPE 0x08` (uplink, root → central) — payload 28 bytes

One journaled event, replayed. Emitted only by the root, in response to
EVENT_LOG_REQ. ⛑ **EN 54-25: no alarm message shall be lost** — this message
is how events that occurred during a serial outage reach the central afterward.

| Off | Size | Field | What it is for |
|----|------|-------|---|
| 0 | 4 | JRN_SEQ | Root-assigned, monotonically increasing journal sequence. The central persists the highest value seen and uses it as SINCE_JRN_SEQ next time. |
| 4 | 1 | LOG_FLAGS | bit0 **LAST** = final entry of this batch (if more remain, the central sends another EVENT_LOG_REQ); bit1 **EMPTY** = journal has nothing newer (offsets 5..27 are zero and must be ignored). |
| 5 | 6 | ORIG_SRC_MAC | The device that originated the event — the frame's own SRC_MAC is the root's. |
| 11 | 17 | EVENT payload (§7.1) | The original event, byte-for-byte, including its original TIMESTAMP and DEV_SEQ — so dedupe and the event history behave exactly as if it had arrived live. |

Replayed events go through the same acceptance pipeline as live ones
(dedupe by `(ORIG_SRC_MAC, DEV_SEQ)`, latching, feed insertion flagged as
"historic"). Live EVENT frames are **not** wrapped — wrapping happens only on
replay, because the root cannot modify authenticated device frames in flight.

### 7.10 INSTALLATION — `MSG_TYPE 0x09` (uplink, board → central) — variable, ≤ 202 bytes

*v3.1, POC round 1 (pocs/POC-BRIEF.md §4.2).* Sent by the board in reply to
`GET_INSTALLATION` (§7.6), over the serial link only. Lets the app show
installation identity and the enrolled device list without the tablet ever
holding `net_psk` or `safr_psk` — those two are **never** carried in this
message.

| Off | Size | Field | What it is for |
|----|------|-------|---|
| 0 | 2 | SYSTEM_ID | |
| 2 | 1 | CHANNEL | |
| 3 | 1 | NET_SSID_LEN (n1, ≤ 32) | |
| 4 | n1 | NET_SSID | |
| 4+n1 | 1 | NAME_LEN (n2, ≤ 32) | installation name |
| 5+n1 | n2 | NAME | |
| 5+n1+n2 | 1 | ENROLLED_COUNT (m) | |
| 6+n1+n2 | ... | ENROLLED[m] | repeated record, see below |

Each `ENROLLED[i]` record:

| Size | Field |
|------|-------|
| 6 | MAC |
| 1 | NAME_LEN (≤ 32) |
| NAME_LEN | NAME |
| 1 | ZONE_LEN (≤ 16) |
| ZONE_LEN | ZONE |

Round 1 only ever enrolls the two AC devices (POC-BRIEF §7 step 2), so the
worst case (2 entries, max-length names/zones) stays well inside
`SAFR_MAX_PAYLOAD`. *(v3.2)* The board now encodes this message from the first
entries of its device table, stopping cleanly at the payload cap; it is the
legacy view for pre-v3.2 tablets. New tablets use `DEVICE_TABLE` (§7.12).

### 7.11 NAME_ANNOUNCE — `MSG_TYPE 0x0A` (uplink) — variable, ≤ 50 bytes

*v3.1, POC round 1 (pocs/POC-BRIEF.md §4.2/§4.3).* Sent once by a node after
boot (and forwarded by the board like any other frame) so the central can
attach the operator-chosen name/zone to a device without waiting on the
enrolled list. `SRC_MAC` (header) identifies which device this is.

| Off | Size | Field |
|----|------|-------|
| 0 | 1 | NAME_LEN (n1, ≤ 32) |
| 1 | n1 | NAME |
| 1+n1 | 1 | ZONE_LEN (n2, ≤ 16) |
| 2+n1 | n2 | ZONE |
| 2+n1+n2 | 1 | ROLE *(v3.2, optional)*: `SAFR_ROLE_*` (0 root-capable AC unit currently root, 1 AC unit, 2 battery leaf). Receivers MUST accept the frame without it (treat as `0xFF` unknown). |

*(v3.2)* Also sent after a `SET_DEVICE` (§7.6) has been applied. A battery leaf
sends it **once after provisioning**, not on every deep-sleep wake.

### 7.12 DEVICE_TABLE — `MSG_TYPE 0x0B` (uplink, board → central, serial only) — variable, ≤ 202 bytes, paged

*(v3.2)* The board's device table (`docs/others/installation-lifecycle-v1.md` §3),
in reply to `GET_DEVICE_TABLE`. One frame per page; the board fills each page up
to `SAFR_MAX_PAYLOAD`. Never carries the code. `INSTALLATION` (§7.10) stays as
the legacy view for pre-v3.2 tablets.

**Unsolicited push (v3.3, 2026-09-27).** The board also sends the full table,
`DST = broadcast`, without a request, the moment its root's TCP session drops
(§9.2 "root gone"). The central applies it exactly like a reply.

| Off | Size | Field |
|----|------|-------|
| 0 | 1 | PAGE (1-based) |
| 1 | 1 | PAGE_COUNT |
| 2 | 2 | TOTAL entries in the table |
| 4 | 1 | COUNT (m) entries in this page |
| 5 | ... | ENTRY[m] |

Each `ENTRY[i]`:

| Size | Field |
|------|-------|
| 6 | MAC |
| 1 | ROLE (`SAFR_ROLE_*`, `0xFF` unknown) |
| 1 | STATE: `0` expected · `1` online · `2` missing · `3` retired |
| 1 | FLAGS: `0x01` SEEN_EVER · `0x02` ANNOTATED · `0x04` PENDING_RENAME · `0x08` HEARD_WHILE_RETIRED · `0x10` PENDING_DECOMMISSION |
| 2 | LAST_SEEN_AGE_S (`0xFFFF` = never) |
| 1 | NAME_LEN (≤ 32) |
| NAME_LEN | NAME |
| 1 | ZONE_LEN (≤ 16) |
| ZONE_LEN | ZONE |

### 7.13 CODE — `MSG_TYPE 0x0C` (uplink, board → central, **setup channel only**) — variable, ≤ 90 bytes

*(v3.2)* Reply to `GET_CODE`. Same layout as the `SET_INSTALLATION`
ARGS: `system_id u16 ‖ channel u8 ‖ mesh_id u8 ‖ ssid_len u8 ‖ ssid ‖ psk_len u8 ‖ psk ‖ safr_psk[16] ‖ name_len u8 ‖ name`.
Encrypted under the setup-channel key (§3.1), header SYSTEM_ID `0x0000`. Never
sent on the mesh.

### 7.14 PARENT_PROBE — `MSG_TYPE 0x0D` (ESP-NOW broadcast) — payload 1 byte

*(v3.2; blueprint §9.2 leaf discovery + lifecycle §6 survey)* Authenticated
with the installation key like every frame; `DST_MAC` = broadcast.

| Off | Size | Field |
|----|------|-------|
| 0 | 1 | PURPOSE: `0` parent discovery (battery leaf looking for an AC parent) · `1` survey (range test, TEST button on a unit with no network) |

### 7.15 PARENT_OFFER — `MSG_TYPE 0x0E` (ESP-NOW unicast, neighbour → prober) — payload 3 bytes

| Off | Size | Field |
|----|------|-------|
| 0 | 1 | PURPOSE (echoes the probe) |
| 1 | 1 | RSSI_SEEN (int8 dBm) at which the probe was received |
| 2 | 1 | LAYER of the answering unit (`0xFF` = not on a mesh) — lets a leaf prefer a shallow parent |

Survey (`PURPOSE = 1`): the prober is any provisioned AC node or leaf with no
path to the board; it sends the probe four times 1.2 s apart under the same
MSG_ID (outlasting a unit's ~3 s router scan). **Every** provisioned unit holding the code answers each copy — AC
nodes, awake leafs and the board (LAYER `0x00` in its offer) — and shows the
RSSI it heard the probe at on its LED for 1 s (green ≥ −75 dBm, yellow ≥ −85,
red); the prober's LED is dark for the 4.5 s window (TEST locked), it counts
one answer per SRC_MAC and blinks once per answering unit in the colour of
`min(RSSI_SEEN, own rx RSSI)`; no answer = one red blink; base pattern back =
unlocked. Parent discovery (`PURPOSE = 0`): only AC
units that are ONLINE answer.

---

## 8. The root event journal ⛑ EN 54-25 "no alarm lost"

- The root appends **every EVENT it forwards or originates** to a journal:
  `{JRN_SEQ, ORIG_SRC_MAC, 17-byte EVENT payload}`.
- Capacity: at least **64 entries** (mock: RAM ring buffer; real hardware:
  flash-persisted so it survives a root reboot — required for certification).
- JRN_SEQ starts at 1 and never resets while the journal persists; the mock
  restarts at 1 each boot (acceptable only because the central treats a
  JRN_SEQ *lower* than its stored value as "journal was reset — request from
  0").
- The journal is drained by EVENT_LOG_REQ/DATA (§7.8/§7.9). Live traffic —
  especially ALARM — always preempts replay traffic in the root's TX queue.

---

## 9. Delivery assurance

### 9.1 ACK / fast-retry state machine

```
sender (needs ACK)                      confirmer
      │ frame (F_ACK_REQ, MSG_ID=n)          │
      ├────────────────────────────────────►│  validate CRC → SYSTEM_ID →
      │                                      │  decrypt → process
      │◄────────────────────────────────────┤  ACK { ACKED_MSG_ID = n, STATUS }
      │
      │ no ACK after 2 s → retransmit (same MSG_ID, FRESH MSG_CTR) ×3
      │ still no ACK → local TROUBLE COMM_FAULT
      │ if the frame was an ALARM → continue per §7.2 (60 s F_RETX
      │ re-announcements, forever, until restore/RESET)
```

- Retransmissions reuse **MSG_ID** (so the receiver can dedupe) but must use a
  **fresh MSG_CTR** (CCM nonces are never reused, even for identical plaintext).
- Receivers deduplicate: EVENTs by `(SRC_MAC, DEV_SEQ)` (§6); everything else
  by `(SRC_MAC, MSG_ID)` within a 30 s window. Process once, **ACK every time**.

### 9.2 Uplink supervision (device → central) ⛑ NFPA 72 ≤ 200 s / EN 54-25 ≤ 300 s

**Root gone (v3.3).** The board knows the root is dead before anyone's silence
rule does: the root's TCP session is aborted by TCP keepalive ~5 s after its last
segment. The board then marks the unit it last saw at LAYER 1 / ROLE root as
`missing` in its device table and pushes the table (§7.12). The central treats
the board's `missing` as authoritative whenever the table is newer than its own
last frame from that unit; any later authenticated frame from the unit makes it
online again on both sides. The silence rule below stays as the backstop and is
what still applies to a non-root node.

**Role change announce (v3.3).** A node whose Mesh-Lite level changed sends
HEARTBEAT + TOPOLOGY as soon as the new path is proven — root: its board session
is up; child: a downlink frame arrived after the change — retrying until both
frames left, then restarts its 15 s / 60 s timers. The board sends its own
HEARTBEAT (up and down) the moment a root connects, which is that proof for the
whole re-formed tree.

| Sender | HEARTBEAT | TOPOLOGY |
|--------|-----------|----------|
| root / relay (powered) | every 15 s | every 60 s |
| leaf (sleeping) | every 60 s (on wake) | — |

**Rule:** if the central hears nothing (no frame of any type) from a known
device for **3 × its heartbeat interval** (45 s powered, 180 s leaf), it must
raise a synthetic TROUBLE "device missing" and mark the device offline. Both
detection times sit inside the 200 s (NFPA) and 300 s (EN 54-25) limits with
margin for one lost heartbeat. Any valid frame restores the device.

### 9.3 Downlink supervision (central → root) ⛑ UL 864 / EN 54-25 both-directions

Heartbeats prove the uplink; nothing in v2 proved the *downlink* more than
hourly. v3 rule: while the link is up, the central sends **CMD LINK_CHECK every
30 s** (F_ACK_REQ). Three consecutive unconfirmed LINK_CHECKs (~36 s worst
case with fast retries) → the central raises a link TROUBLE ("falha no enlace
de descida") — well inside 200 s.

The central's **USB link status** additionally follows the stricter local rule:
the link is "connected" only when the port is open **and** a structurally valid
frame arrived within the last **20 s** (one 15 s board HEARTBEAT plus margin;
was 10 s, which would flap on a healthy link). Past that the link is
**stalled**: the port is open — a USB-UART adapter stays enumerated when the
board behind it dies — but the board is silent. Every device is then offline at
once and the central raises one TROUBLE ("placa sem resposta"), restored when
the board's frames return. *(v3.3, 2026-09-27; before, a dead board behind an
open port was only noticed by LINK_CHECK ≤ 36 s and per-device silence 45 s.)*

**Node-side board supervision (v3.3).** A node counts the board as reachable
while any downlink frame arrived within the last 90 s — in steady state the
board's downlink HEARTBEAT (§7.3) every 15 s, i.e. 6 missed heartbeats. A node
whose mesh is up but whose board is silent stays in "finding the network" (LED
white breathe) and its TEST button runs the range survey instead of a walk test.

### 9.4 Link-quality trouble

Receivers count CRC failures and auth failures per rolling window. Sustained
corruption (≥ 5 failures within 60 s) must raise a TROUBLE ("qualidade do
enlace degradada") even if some frames still get through — degraded is not
"working". ⛑ UL 864 monitoring for integrity; EN 54-25 interference immunity.

---

## 10. Receiver algorithm (both sides)

1. Scan the byte stream for `0xA5`.
2. Read LEN (bytes [2..3]); reject if `< 34` or `> 250`; wait for LEN bytes.
3. Verify CRC16 over `[0 .. LEN-3]` against `[LEN-2 .. LEN-1]`.
   Fail → **discard exactly 1 byte** (the false SOF) and rescan.
4. Check VER: `0x03` full processing; `0x02`/`0x01` decoded read-only by the
   central for old stored packets; anything else → "bad version" diagnostic.
5. Check SYSTEM_ID: foreign → count + drop (no decryption attempt).
6. Check F_ENC: absent in production mode → `plaintext_rejected` diagnostic,
   stop (§4.1).
7. Build nonce from header, decrypt+verify CCM (AAD = bytes 0..29).
   Tag fail → diagnostic "auth failed"; never update device state from it.
8. Replay check (§4). Parse payload by MSG_TYPE.
9. Dedupe (§9.1) — EVENTs by DEV_SEQ, others by MSG_ID.
10. If F_ACK_REQ (and frame was fully valid): send ACK — even for duplicates.
11. Apply latching rules (§7.1.4).

---

## 11. Compliance work that lives OUTSIDE this protocol

Recorded so nobody mistakes the protocol for the whole certification story:

- **Root as certified control unit**: watchdog, supervised redundant power
  (mains + battery, both monitored), flash journal, and local sounder output —
  UL 864 / EN 54-2 hardware requirements.
- **Battery runtime characterization**: BATT_LOW must fire with ≥ 7 days
  (NFPA 72) / ~30 days (EN 54-25) of operation left — needs real hardware
  power profiling; the % threshold is then derived, not guessed.
- **Trouble re-sound**: UL 864 requires unacknowledged troubles to re-annunciate
  every 24 h at the panel — an app/panel behavior, not a wire format.
- **Event history retention**: NFPA 72 requires a panel event log; the app's
  Drift `DeviceEvents` table is append-only and must stay that way.
- **Sleeping-leaf command mailbox**: deferred until leaves drive sounders or
  relays; when they do, a pending-command flag piggybacked on heartbeat ACKs
  will be added (a leaf in alarm already stays awake — §7.2). *(v3.2)* The
  lifecycle commands `SET_DEVICE` and `DECOMMISSION` addressed to a leaf wait
  for the same mailbox (`docs/others/installation-lifecycle-v1.md` §5.2).

---

## Appendix A — Deterministic test vectors

On boot, the mock firmware emits these three frames **before** starting the
simulation, with fixed counters and payloads, so any implementation can be
checked bit-for-bit. The Dart test suite generates the same frames and the
captured-fixture test asserts the firmware bytes match.

*(v3.2)* Two more vectors are added by the Phase 1 app work, generated by the
same Dart tool and stored in `test/fixtures/setinst_vectors.json` for the
firmware host test to replay: **V-SETINST** (setup-channel key derivation from
`id = "dev-00000001"`, `pop = "0123456789ABCDEF"`, plus one `SET_INSTALLATION`
frame under SYSTEM_ID `0x0000`) and **V-DEVTAB** (one `DEVICE_TABLE` page with
two entries). Until they exist, the v3.2 messages are specified, not verified.

Common inputs:

```
PSK        = 25118BA1DD19B84509DF36E9416B8DBE
SYSTEM_ID  = 0x5346
SRC_MAC    = 5A:46:52:00:00:01   (virtual root)
DST_MAC    = FF:FF:FF:FF:FF:FF
TTL=7 HOPS=0 FLAGS=0x01 (F_ENC)   BOOT_CTR=0x0001
```

| # | MSG_TYPE | MSG_ID | MSG_CTR | Payload (plaintext hex) |
|---|----------|--------|---------|--------------------------|
| V1 | EVENT 0x01 | 0x0001 | 0x00000001 | `03 01 68 6E 2F 00 05 55 10 68 02 26 2A 00 00 00 01` (ALARM/SMOKE, ts 0x686E2F00, AC_OK+ON_BATT, 85%, smoke 0x1068, 55.0 °C, 42%, no fault, DEV_SEQ 1) |
| V2 | HEARTBEAT 0x02 | 0x0002 | 0x00000002 | `68 6E 2F 01 00 00 0E 10 01 64 00 FA 7F 00 00 00 00 00 01 00` (ts, uptime 3600, AC_OK, 100%, 25.0 °C, rssi n/a, parent = central, layer 0) |
| V3 | TOPOLOGY 0x03 | 0x0003 | 0x00000003 | `68 6E 2F 02 00 00 00 00 00 00 00 01 7F 02 5A 46 52 00 00 02 BE 5A 46 52 00 00 03 C4` (root, layer 0, parent central, 2 children with RSSI −66/−60) |

Full frame hex (header + ciphertext + tag + CRC), generated and asserted by
`test/safr/safr_v3_vectors_test.dart` (regenerate with
`dart run tool/print_safr_v3_vectors.dart`); firmware must reproduce these
bytes exactly:

```
V1 (65 bytes):
A503004101000153465A4652000001FFFFFFFFFFFF07000100010000000141AF9429BA4D87A82CC6B4BE0C598D6A9244EE915438245C31277D89868FA4723F5820

V2 (68 bytes):
A503004402000253465A4652000001FFFFFFFFFFFF07000100010000000212D0A08D33693CEA467B1F3810E79100A6AEEB92C38A0DFC61192C6FD3A987FA85DFF5C9E9ED

V3 (76 bytes):
A503004C03000353465A4652000001FFFFFFFFFFFF070001000100000003D92DFFDAFE51A2120096E2C02AA08E7655180495E70530D730B37389B0278118BAD4AE559B6C5FDE8530F8D233A1
```
