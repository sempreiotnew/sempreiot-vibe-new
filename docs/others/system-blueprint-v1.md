# SempreIoT — System Blueprint v1 (follow strictly)

_2026-09-14. This is the authoritative step-by-step for installation, network formation, operation and the engineering work that implements it. (`mesh-architecture-options.md`, which kept the reasoning and trade-offs, is no longer in the repo); `app-sempreiot-central.md` documents the app as it is today. When something here conflicts with another doc, this one wins. Change it only by editing it._

---

## 0. Vocabulary — use these words and no others

| Word | Meaning |
|---|---|
| **Board** | **The device attached to the tablet by USB** (your ESP32 board). AC + battery. It raises the installation's Wi-Fi access point and runs the safety logic (latching, journal, supervision, sirens). It is the *control unit*. It is **not** a mesh node and is **never** the root. |
| **Tablet** | Android tablet running the app in CENTRAL mode. Screen and buttons for the operator. Talks to the board over USB only. Creates no Wi-Fi. May have no camera. May or may not have internet; the fire system never depends on it. |
| **AC device** | Any product powered from mains (siren, I/O module, AC detector, repeater). Runs ESP-Mesh-Lite. Root-capable. |
| **Battery detector** | A detector powered from batteries. Sleeps. Talks by ESP-NOW to one AC device. Never root, never relay. |
| **Root** | The AC device currently connected directly to the board's access point. Chosen automatically by Mesh-Lite; replaced automatically when it dies. |
| **The code** (installation bundle) | `SYSTEM_ID` (16-bit, ≠ 0), `NET_SSID = "SIOT-<SYSTEM_ID hex>"`, `NET_PSK` (16 random chars), `SAFR_PSK` (16 random bytes), `CHANNEL` (1/6/11), `MESH_LITE_ID` (derived). Every unit of one installation — board included — holds the same code. |
| **Sticker** | Factory QR on every unit, board included: `{id, mac, pop}`; `pop` is a per-unit 16+ char secret also burned in NVS. |
| **Installer app / viewer app** | The same Flutter app on a phone. "Installer" functions (create installation, provision units) work **offline**. "Viewer" functions need internet. |
| **Setup network** | The Wi-Fi access point `SIOT-SETUP-<id>` a unit raises while unprovisioned; WPA2 password = its `pop`. |

---

## 1. Rules that must never be broken

1. The board raises the installation Wi-Fi. Nothing else does. The tablet never does.
2. The board is never a Mesh-Lite node. Root is always an AC device, chosen by Mesh-Lite.
3. Battery detectors never associate to Wi-Fi after provisioning. ESP-NOW only.
4. The code is created once per installation and reaches every unit — board included — the same way: sticker → app joins the unit's setup network → app pushes the code.
5. The tablet always learns the **roster** from the board over USB. It holds the **code** from an encrypted backup QR (phone → tablet, passphrase) or because it created it (Case B). The board never sends the code over USB except to a tablet that proves the board's own `pop` (`GET_CODE`, `installation-lifecycle-v1.md` §4). Never from the internet.
6. No step of installation or operation requires the internet. The cloud only mirrors what the tablet already knows, when internet exists.
7. SAFR v3 stays the end-to-end protocol on every hop (USB, Mesh-Lite, ESP-NOW). Mesh-Lite and ESP-NOW only carry bytes.
8. Retries are SAFR's (fresh MSG_CTR). Never use `esp_mesh_lite_try_sending_msg()` for SAFR frames.
9. A unit is "installed" only when the board has heard an authenticated frame from it. The app never shows "assumed".
10. Root-capable = on AC. If a site has no AC device, it has no mesh; battery detectors work standalone until one appears.

---

## 2. Factory state of every unit (board included)

- NVS: `id`, `pop`, no code. Sticker printed with `{id, mac, pop}` plus a peel-off duplicate.
- On power-up with no code, or after a 5 s button hold (factory reset — already implemented in `pocs/patinha`): **setup mode** for 10 minutes — LED white blink — raising the setup network `SIOT-SETUP-<id>` with WPA2 password `pop`. Battery units stop after **2 minutes without a provisioning request or a phone joining** (2026-09-28, protocol §12.9; was 10; a phone merely associated does not count) and in any case **10 minutes after boot**, then deep sleep with the button as the **only** wake source — a short press opens another window; AC units keep it up.
- LED language everywhere (proposal, colours not final): **white blink** = waiting for setup (also after a factory reset; the only white blink) · **white solid** = factory-reset armed (button held ≥ 5 s) · **white breathe** (slow dim fade) = configured, no path to the board yet (decided 2026-09-24; the hard white blink stays setup-only) · **green solid 3 s** = installed · **red** = fault · **blue short blink** = test button pressed (as in `patinha`) · survey mode (`installation-lifecycle-v1.md` §6, unit provisioned but no path to the board): passive unit **1 s green / yellow / red solid** = how well it heard the probe (≥ −75 / ≥ −85 / below dBm) · pressed unit goes **dark = locked** for ~5 s and blinks **once per answering unit** in that link's colour, **one red blink** = nobody; breathe back = unlocked. **Leafs** (protocol §12.8): no LED at all while asleep, no white breathe; a press gives an **immediate blue blink** instead of the dark period, and after provisioning the unit does by itself what a press does — the walk test: blue → **cyan** (the panel confirmed) or **one red blink**; with no path to the board, the survey blinks (amended 2026-09-29: cyan is the one "confirmed" colour, no green verdict on a leaf).

---

## 3. Installation procedure

### 3.1 Case A — installer arrives first (no board on site yet)

| Step | Who / where | Action | What happens inside |
|---|---|---|---|
| A1 | Installer, phone, offline | "New installation" → name it | Phone generates the code, stores it locally (encrypted), can show it as an *installation QR*. |
| A2 | Installer, each AC device and battery detector | Power it (white blink). "Add device" → scan sticker → **type the unit's name and pick its zone** (e.g. "Detector — corredor 2º andar") → confirm. | App joins `SIOT-SETUP-<id>` using `pop`; `GET /info` → `POST /identify {id, proof=HMAC(pop, nonce)}` → `POST /provision {envelope, name, zone, epoch}` where envelope = code encrypted with AES-CCM under a key derived from `pop` + nonce; `GET /status` → `stored`. App drops the connection. Unit stores code + its own name. Unit LED: green blink. App records the unit as *enrolled, not yet online* with its name. ~20 s per unit. Mount it. |
| A3 | Installer, the board | Same as A2: power the board, scan its sticker, name it (installation name), push the code. The app also pushes the enrolled list (`POST /enroll [{mac,id,name,zone}]`). | Board stores the code and the enrolled list (names included) in NVS. Board LED green blink. |
| A4 | Installer | Mount the board. Plug the tablet's USB. | Board raises `NET_SSID` on `CHANNEL`. Tablet app (CENTRAL mode) reads the code and the enrolled list from the board over USB (SAFR `GET_INSTALLATION`). Network forms (§4). |
| A5 | Installer, tablet | Every unit already shows its name. "Blink it" to confirm a unit, rename if needed, walk test (§6.4). | Names live in the board's registry; the tablet edits them there. |

Order inside A2/A3 does not matter; the board can be provisioned first or last.

### 3.2 Case B — board and tablet are set up first

| Step | Who / where | Action | What happens inside |
|---|---|---|---|
| B1 | Installer, tablet | Mount the board, plug USB, power. Tablet: "New installation" → name it → scan or type the **board's sticker** (`id`, `pop`). | Tablet generates the code and sends it to the board over USB (`SET_INSTALLATION` on the setup channel: SYSTEM_ID `0x0000`, key derived from the board's `pop` — protocol §3.1/§7.6). Board stores it, ACKs, reboots and raises `NET_SSID`. |
| B2 | Installer, tablet + phone | Tablet shows the **encrypted** installation QR (passphrase) on its screen; the phone scans it and types the passphrase. | Phone now holds the code (no internet, no tablet camera needed). Same QR is how a second installer or a replacement tablet gets the code. |
| B3 | Installer, each unit | As A2 (scan, name, zone, confirm). | As A2, except the unit finds the network immediately and goes to `online`; the tablet shows it green **with its name** within seconds (AC device) or on its next wake (battery detector). The unit's first HEARTBEAT carries its name so the board needs no separate list. |
| B4 | Installer, tablet | As A5. | — |

### 3.3 Both cases — what the phone must never need
Internet, the tablet's camera, the customer's router, or being near the board while provisioning a detector.

---

## 4. Power-on and network formation (automatic, no user action)

1. Board boots, reads the code from NVS, raises access point `NET_SSID` / `NET_PSK` on `CHANNEL`, static IP `192.168.4.1`, DHCP on. Starts the SAFR engine and the USB bridge. Sends `LINK_CHECK`s to the tablet as today.
2. Every AC device boots, reads the code, starts Mesh-Lite with router config = `NET_SSID`/`NET_PSK`, mesh ID = `MESH_LITE_ID`, node type = *root or child*, max level 4, fixed channel.
3. AC devices that see `NET_SSID` connect to the board and compare RSSI; the best stays as **root** (level 1); the others disconnect from the board and join the root (level 2), then deeper as needed. Mesh-Lite does all of this.
4. Each AC device sends HEARTBEAT every 15 s (and TOPOLOGY only when its layer changes), as SAFR frames, upward to the board (`esp_mesh_lite_send_raw_msg_to_root`, and root → board over its Wi-Fi link).
5. Each battery detector wakes on its RTC timer. If it has no bound parent (or the bound parent stopped answering), it broadcasts `PARENT_PROBE` by ESP-NOW; every AC device in reach answers `PARENT_OFFER {mac, level, load}` (authenticated). The detector binds to the best, stores the MAC in RTC memory, sends HEARTBEAT to it, receives the parent's ACK, sleeps.
6. The board marks each unit *online* on its first authenticated frame (a unit's first HEARTBEAT after provisioning carries its name and zone — new `NAME_ANNOUNCE` payload); the tablet shows it green with its name. Board sends TIME_SYNC down the tree on link-up and hourly; RTCs keep time in between.

Expected cold start to all-green: about 2 minutes for 50 units.

---

## 5. Normal operation

### 5.1 Battery detector (every 60 s — fixed; protocol §12)
Wake → radio on, installation channel → drain the **outbox** (events stored while no parent answered) → ESP-NOW HEARTBEAT (unicast, `F_ACK_REQ`) to the bound parent → wait ≤ 100 ms for the parent's 9-byte ACK (carries **PENDING** + count, **NO_PATH**, **EPOCH**, **CHANNEL** — the leaf sets its clock and channel from it, no TIME_SYNC ever) → if PENDING, stay awake and receive the queued frames (≤ 4) → sleep. Hard budget 500 ms outside alarm; no LED in sleep. Smoke sensor samples autonomously and wakes the ESP by GPIO 4 on threshold. **2 consecutive misses** → `PARENT_PROBE` and re-bind (done at ≈ 120 s, before the board's 180 s rule); nobody answers → local COMM_FAULT (one red blink + trouble chirp per wake), probe every wake while nodes are heard, every 5 min when nobody is. The interval was "configurable 60–150 s"; it is **60 s fixed** until POC D measures the battery (protocol §12.12: 3 × 150 s breaks both standards' limits).

### 5.2 AC device
Always associated. Answers `PARENT_PROBE` only while ONLINE. Acknowledges every leaf frame at once (that ACK is the leaf's permission to sleep) and takes **custody**: stores-and-forwards the detector's events upward with SAFR retries until the board ACKs (queue bounded, ALARM never dropped). Holds a **mailbox** (≤ 4 queued downlink frames per known detector, same-command replace, expiry 180 s) and raises the PENDING flag with the count in that detector's next ACK; the board's device table is the truth behind it. Sets NO_PATH in the ACK while it has no path to the board. Forwards an ALARM heard by **broadcast** from any leaf, bound or not. Protocol §12.5, §12.6, §12.11.

### 5.3 Board
Supervision: AC device silent > 45 s or battery detector silent > 3 × its interval → synthetic TROUBLE "device missing" (as today). Journal every EVENT to flash. Latch every ALARM until operator RESET. Drive its own fire/fault/power LEDs and sounder regardless of the tablet. Bridge every frame to the tablet over USB.

### 5.4 Tablet
Everything the app does today over USB, unchanged. When internet exists, mirror state to the cloud for viewers.

---

## 6. Alarm sequence

1. Detector senses smoke → wakes → `EVENT ALARM` with `F_ACK_REQ` by ESP-NOW to its parent → detector stays awake. If the unicast fails at the MAC layer (parent dead or out of range) the detector resends the same frame **at once as an ESP-NOW broadcast**; every AC device that hears it forwards it, the board keeps one copy (protocol §12.6).
2. Parent forwards up the mesh to the root → board over Wi-Fi → tablet over USB.
3. Board latches, journals, drives its sounder, applies cause-and-effect and sends `COMMAND SOUND` down the mesh to the selected sirens. **Default rule:** every siren also sounds on any *authenticated* ALARM it overhears on the mesh, board reachable or not.
4. Board ACKs the detector end-to-end (the detector tells the parent's custody ACK from the board's by `SRC_MAC`; only the board's lets an alarm rest). No ACK within 2 s → detector retries 3× (fresh MSG_CTR) → then `PARENT_PROBE` + re-bind → keep going, awake and sounding. Every 60 s the detector re-announces the same ALARM (`F_RETX`, same DEV_SEQ) until RESET. An alarm that clears before any ACK is stored (ALARM + RESTORE) in the detector's outbox and delivered on the next wake with a parent.
5. Operator presses SILENCE (sirens off, latch stays) or RESET (board sends RESET down; latch clears only after the root ACKs).

### 6.4 Walk test (commissioning)
Installer presses the test button on each detector → `MANUAL_TEST` ALERT → tablet ticks the unit with time and RSSI; the unit shows blue (sent) then **cyan** (the panel's ACK came back) — on a battery detector too, which stays awake ≈ 3 s for it (protocol §12.8). Tablet flags any battery detector whose bind-time `TOPOLOGY` (protocol §12.7) listed fewer than two parent candidates or a link below −85 dBm. Tablet exports the installation report (PDF): units, zones, MACs, firmware, test times, RSSI.

---

## 7. Failures

| Failure | Automatic behaviour | Operator sees |
|---|---|---|
| Non-root AC device dies | Its children re-parent (Mesh-Lite); its detectors re-bind by probe | TROUBLE "missing" after 45 s; restores by itself |
| Root dies | Level-2 AC devices reconnect to the board's access point; best becomes root (Espressif: < 50 s; POC-B measures) ; its detectors re-bind | Same |
| Board dies | Tablet loses USB → trouble. Mesh keeps running without an upward target; detectors keep getting parent ACKs; alarms get no end-to-end ACK → originating unit raises COMM_FAULT and keeps sounding; sirens sound on overheard alarms | USB link trouble; local protection continues |
| Tablet unplugged | Board keeps latching, journaling, supervising, sounding, showing its own LEDs | On return: `EVENT_LOG_REQ` backfill, deduped |
| Site mains fails | Board on battery, AC_LOST trouble; AC devices without backup drop and are reported missing; detectors re-bind to survivors | Troubles; siting rule: each detector should have ≥ 2 AC devices in reach |
| Foreign/neighbour unit | Wrong `NET_PSK` → cannot join; wrong `SAFR_PSK` → CCM fails → key-mismatch diagnostic; other `SYSTEM_ID` → dropped before decrypt | Diagnostic only |

---

## 8. Maintenance

- **Every lifecycle flow** (add later, second installer, replace, retire, rename, lost phone, dead board, dead tablet, re-key, survey mode) is specified step by step in `installation-lifecycle-v1.md` §5–§6. Summary:
- **Add a unit later:** §3 step A2/B3 with any phone that holds the code. **Replace a unit:** add the new one, give it the old one's name and zone, then retire (and, if still powered, wipe) the old one (`SET_DEVICE`, `RETIRE_DEVICE`, `DECOMMISSION`). The board's one-step `REPLACE_DEVICE` exists in the protocol but the tablet no longer offers it (2026-10-03).
- **Replace the board:** provision the new board like any unit (A3) from any phone's copy of the code, or arm it from the tablet (B1); plug USB; everything rejoins and the board rebuilds its device table from what it hears. The tablet can resend its names.
- **Factory reset a unit:** 5 s hold → code wiped → **white blink** (setup mode) → the tablet shows it missing until retired/forgotten.
- **Change channel:** tablet → board → `SET_CHANNEL {channel, switch_at}` down the mesh; detectors learn it from their next ACK; board switches last.
- **Firmware:** AC devices via Mesh-Lite OTA; detectors via the PENDING flag ("update pending" → stay awake → pull from parent).

---

## 9. Engineering work — build in this order

### 9.1 Firmware images (ESP-IDF, FreeRTOS)
1. **`board`** — no `mesh_lite` dependency. SoftAP + DHCP; TCP/raw listener for frames from the root; SAFR engine ported from `mocked-device/main/mesh_sim.c` (ACK downlink, retry critical uplink, journal → flash partition); USB/UART bridge to the tablet (`CONFIG_ESP_CONSOLE_NONE`); setup-network provisioning endpoint (§3); local LEDs + sounder; watchdog.
2. **`node`** (AC device) — `mesh_lite` (router = code; node type root-or-child; max level 4; fixed channel); ESP-NOW receiver for detectors; `PARENT_OFFER`; mailbox + PENDING flag; store-and-forward with SAFR retries; sensors/siren/IO per product; setup-network provisioning endpoint.
3. **`leaf`** (battery detector) — no `mesh_lite`; deep sleep + RTC timer + sensor GPIO wake; ESP-NOW send/ACK; `PARENT_PROBE`/bind in RTC memory; PENDING fetch; standalone alarm; setup-network provisioning endpoint.

### 9.2 SAFR v3.1 additions (edit `docs/safr/protocol-safr-v3.md`)
- `COMMAND SET_INSTALLATION` / `GET_INSTALLATION` (USB, tablet ⇄ board) — carries the code and the enrolled list. **Done in protocol v3.2** together with `DEVICE_TABLE`, `SET_DEVICE`, `RETIRE/UNRETIRE/REPLACE/DECOMMISSION/FORGET_DEVICE`, `GET_DEVICE_TABLE`, `GET_CODE` (`installation-lifecycle-v1.md`).
- `NAME_ANNOUNCE` (unit → board, sent after provisioning and on every boot): `{name ≤ 32 bytes, zone ≤ 16 bytes}` so the board's registry never depends on the phone's list.
- `PARENT_PROBE` (leaf → broadcast) and `PARENT_OFFER` (node → leaf), authenticated with `SAFR_PSK`. **Specified in v3.2 (§7.14/§7.15)** with a `purpose` byte; `purpose = 1` is the **survey mode**: TEST button on a unit that has no network yet → range test between units without the board (`installation-lifecycle-v1.md` §6).
- ACK STATUS bit **PENDING** (0x04) — "a command is queued for you; stay awake". **Done in protocol v3.4 §12** (2026-09-28) together with `NO_PATH` (0x08), the leaf ACK `EPOCH` + `CHANNEL` extension, the mailbox, custody + outbox, the alarm broadcast fallback, leaf `TOPOLOGY` and the 2-minute setup window.
- `COMMAND SOUND` (board → sirens) and `SET_CHANNEL`.
- Enrollment record: `{mac, id, name, zone, state: enrolled|online|missing|retired}`.
- Cap `LEN ≤ 250` (ESP-NOW payload limit).
- Demote TTL/HOPS to diagnostics filled from Mesh-Lite level; delete relay-forwarding text.

### 9.3 Provisioning contract (`mocked-device-autoconnect/server.js` is the spec — update it)
- Setup network `SIOT-SETUP-<id>`, WPA2 = `pop`.
- `GET /info` → `{id, mac, model, fw, state, nonce}`; `POST /identify {id, proof}`; `POST /provision {envelope, epoch, name?, zone?}`; `POST /enroll [...]` (board only); `GET /status` → `stored | joining | online | failed`.
- States: `idle → identified → stored → joining → online | failed`.

### 9.4 App (Flutter)
- Installation entity + code generation + installation QR (show and scan).
- Programmatic Wi-Fi join (`WifiNetworkSpecifier` / `NEHotspotConfiguration`) — remove the "open Wi-Fi settings" step from `connect_wifi_step.dart`.
- Wizard steps: scan sticker → **name + zone** → connect → identify → provision → result (`stored`/`online`), enrolled list, "blink it", walk test, report. Name is mandatory at setup; zone from a list the installer defines once per installation.
- CENTRAL mode: `GET_INSTALLATION` on link-up; unit registry keyed by MAC with `enrolled/online/missing/retired`; naming; SILENCE/RESET as today.
- Remove the fake dashboard numbers; feed them from the registry.

### 9.5 POCs, in order, each with a written result in `docs/phases-development/`
1. **A — board + mesh bring-up**: board access point + bridge; two AC nodes; frames from level 2 reach the tablet. Pass: latency ≪ 1 s, 24 h stable.
2. **B — root failover**: cut the root's power. Pass: new root and all nodes back < 120 s (target < 60 s), no ALARM lost.
3. **D — leaf power**: one detector, ESP-NOW heartbeat + ACK, current meter, 60 s and 150 s cadence. Pass: meets the battery-life target on the chosen pack; otherwise change pack or cadence before continuing.
4. **C — alarm during failover + PENDING mailbox to a sleeping detector**. Pass: ≤ 10 s alarm on a healthy network; command delivered within one heartbeat interval.
5. **F — provisioning end to end** (Case A then Case B) with the updated `server.js` and real firmware. Pass: no "assumed" ever; 20 s per unit.
6. **E — scale**: 50 units, then simulated 250. Pass: < 1 % loss, board CPU/heap headroom.

---

## 10. Decisions closed by this blueprint
Mesh-Lite for AC devices; board above the mesh as the access point; automatic root; ESP-NOW for battery detectors; parent-ACK for heartbeats and board-ACK end-to-end for ALARM/TROUBLE; sirens sound on overheard alarms; code created by whichever app comes first and always read by the tablet from the board over USB; v1 provisioning through each unit's setup network (ESP-NOW push by the board is a v2 optimisation).

## 11. Still open
- Full device list beyond detectors and sirens, and which need downlink.
- Battery pack and target life (decided by POC-D). Protocol §12.12 gives the wake cost and the standards' minimum life (NFPA 72 ≥ 1 year, EN 54-25 ≥ 3 years — verify against purchased editions); at 60 s the rough estimate is ≈ 7 months on 2 500 mAh, so the pack, not the protocol, closes this.
- Chip per product: classic ESP32-WROOM vs S3 (USB bridge vs native USB; deep-sleep boot time).
- Whether battery detectors interlink peer-to-peer when no AC device exists.
- Lab pre-submittal review of the board as control unit (ISO 7240-2 / UL 864) — book it before freezing the board's hardware.
