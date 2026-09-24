# POC round 1 — task brief for the implementing session

_You are a Claude session asked to implement this POC. This brief is your contract. Read it fully before touching anything. Where it says STOP, stop and ask Talles. Do not re-decide the architecture: it was settled and is written in `docs/others/system-blueprint-v1.md`._

---

## 0. Hardware facts — must be filled in by Talles before you start

| Fact | Value |
|---|---|
| Chip on the three boards | `<classic ESP32-WROOM-32 / ESP32-S3-WROOM-1>` |
| Real SempreIoT PCB or dev kit | `<pcb / devkit>` |
| How the board reaches the tablet | `<native USB-Serial-JTAG (S3) / external UART bridge chip on UART0 / other>` |
| ESP-IDF version installed | `<e.g. v5.5.2 — see pocs/patinha/README.md>` |
| Mesh-Lite component version to pin | `<e.g. espressif/mesh_lite ^1.0.2>` |
| Tablet | `<Android version; has camera? yes/no>` |
| Phone for the installer app | `<Android/iOS version>` |

**If any cell still contains `<…>`: STOP and ask.** Do not guess the chip; it changes the UART/USB code path and the Mesh-Lite target.

---

## 1. Read in this order (all paths relative to the repo root)

1. `docs/others/system-blueprint-v1.md` — the rules and flows. §0 vocabulary, §1 rules, §3 installation, §4 network formation, §9 engineering. Non-negotiable.
2. `docs/safr/protocol-safr-v3.md` — the wire format. Every frame on every hop (USB, Mesh-Lite, ESP-NOW) is a SAFR frame. Appendix A vectors must still pass.
3. `docs/others/app-sempreiot-central.md` — how the Flutter app is structured today; §5 (serial/SAFR pipeline) and §7 (provisioning wizard) are the parts you will touch.
4. `mocked-device/main/` — `safr_frame.[ch]`, `safr_proto.h`, `mesh_sim.c`: the C implementation of SAFR framing/CCM and the root duties (ACK downlink, retry critical uplink, journal). You will port from here, not rewrite.
5. `mocked-device-autoconnect/server.js` + `README.md` — the current provisioning HTTP contract. You will replace it with the contract in §5 below and keep the mock in sync.
6. `pocs/patinha/main/patinha.c` — GPIO map, debounce, 5 s factory-reset hold, LED engine. Reuse.
7. ~~`docs/mesh-architecture-options.md`~~ — this file is not in the repo; the blueprint (`docs/others/system-blueprint-v1.md` §4) is the only architecture reference.
8. Espressif references (fetch, do not assume): the `espressif/mesh_lite` component README and `components/mesh_lite/User_Guide.md` for API names and Kconfig symbols (router config, node type, allowed levels, mesh ID, raw message APIs, broadcast semantics); ESP-IDF docs for `esp_wifi` SoftAP, `esp_http_server`, `nvs`, `mbedtls_ccm`, `esp_hmac`/`mbedtls_md`.

---

## 2. Scope of round 1 (three boards)

**Goal:** prove the backbone and the setup flow end to end with the real app on the tablet.

- **Board A = the board** (the device attached to the tablet by USB): raises the installation access point, bridges SAFR frames between the mesh and the tablet, answers the tablet's downlink like `mesh_sim.c` does today.
- **Boards B and C = AC devices**: run Mesh-Lite against the board's access point; one becomes root, the other joins under it; both emit SAFR HEARTBEAT/TOPOLOGY and react to downlink.
- **Setup flow**: all three boards start unprovisioned and receive the code from the phone app through their setup network (blueprint §3, Case A). Case B (tablet creates the code) is included only if time allows.
- **Failover**: cut the root's power; the other AC device must become root by itself and traffic must resume.

**Explicitly out of scope for round 1:** ESP-NOW and battery detectors (`PARENT_PROBE`/`PARENT_OFFER`, mailbox/PENDING), the flash journal on the board (RAM ring buffer as in the mock is enough), OTA, cloud/MQTT changes, the viewer app, `SET_CHANNEL`, sirens' cause-and-effect, any certification hardware (watchdog, indicators).

---

## 3. Repository layout to create

```
pocs/
  POC-BRIEF.md                 ← this file
  RESULTS.md                   ← you write the measurements here (template in §8)
  components/
    safr/                      ← SAFR v3 codec ported from mocked-device (frame build/parse, CCM, CRC, counters)
    siot_prov/                 ← setup network + HTTP provisioning server + code storage in NVS (shared by board and node)
    siot_led/                  ← LED engine from patinha (white/green/red/blue patterns per blueprint §2)
  board/                       ← ESP-IDF project: access point + TCP listener + USB/UART bridge + root duties
  node/                        ← ESP-IDF project: Mesh-Lite AC device + SAFR emitter + root-forwarder
  tools/
    make_sticker.py            ← generates {id, mac, pop}, writes NVS factory CSV/bin, prints QR PNG
    failover_timer.py          ← reads the tablet-side or serial log and reports time-to-recovery
```

Do not modify `mocked-device/` or `pocs/patinha/`; copy from them.

---

## 4. Firmware behaviour, per image

### 4.1 Shared: `siot_prov` (blueprint §2–§3)
- Factory NVS namespace `siot_fact`: `id` (string), `pop` (16+ chars). Written by `tools/make_sticker.py` via `nvs_partition_gen`, flashed to the `nvs` partition. Never generated at runtime.
- Installation NVS namespace `siot_inst`: `system_id` (u16), `net_ssid`, `net_psk`, `safr_psk` (16 bytes), `channel` (u8), `mesh_id`, `name`, `zone`, `enrolled` (blob, board only).
- If `siot_inst` is empty at boot, or the button is held ≥ 5 s at any time: **setup mode** — erase `siot_inst`, LED white blink, SoftAP `SIOT-SETUP-<id>` WPA2 password = `pop`, `esp_http_server` on port 80 with the endpoints in §5. Timeout 10 min on AC units is *not* applied in this POC (keep it up).
- On successful `/provision`: store `siot_inst`, LED green blink, reboot into normal mode after `/status` has been polled at least once or after 30 s.

### 4.2 `board`
- Normal mode: SoftAP = `net_ssid`/`net_psk` on `channel`, hidden = false, max 8 STA, static IP 192.168.4.1, DHCP server on. No Mesh-Lite dependency.
- TCP listener on 192.168.4.1:5340. Exactly one client expected (the current root); accept re-connections (a new root after failover). Stream = raw SAFR frames; reframe with SOF+LEN+CRC exactly like `mocked-device.c` `rx_task`.
- Tablet link: SAFR over the serial path named in §0 (USB-Serial-JTAG driver on S3, or UART0 via bridge chip). `CONFIG_ESP_CONSOLE_NONE=y`. Never printf on that port.
- Root duties ported from `mesh_sim.c`: ACK tablet downlink (LINK_CHECK, TIME_SYNC, COMMAND) with `SRC_MAC` = board MAC; forward every uplink frame from TCP to the tablet unchanged; forward tablet downlink to TCP (the root broadcasts it into the mesh); journal EVENTs in a RAM ring buffer and answer `EVENT_LOG_REQ`.
- **Compatibility shim so the current app works:** the board emits its own HEARTBEAT every 15 s and TOPOLOGY every 60 s with `LAYER = 0`, `NODE_ROLE = 0 (root)`, `PARENT_MAC = 00:00:00:00:00:01`, children = the AC devices it currently hears. The app's `meshLinkStateProvider` needs a layer-0 device to show "mesh connected"; the AC devices report `LAYER = their Mesh-Lite level` (1, 2, …).
- New SAFR v3.1 downlink `COMMAND GET_INSTALLATION (CMD 0x10)` → board replies `INSTALLATION (MSG_TYPE 0x09)` carrying `{system_id, net_ssid, channel, name, enrolled[]}` — **never** `net_psk` or `safr_psk` over USB in this POC. `SET_INSTALLATION (CMD 0x11)` is Case B; implement only if time allows.
- New uplink `NAME_ANNOUNCE (MSG_TYPE 0x0A)`: forwarded like any other frame.

### 4.3 `node` (AC device)
- Normal mode: `esp_mesh_lite` with router SSID/password = `net_ssid`/`net_psk`, mesh ID = `mesh_id`, fixed `channel`, node type = **root or child** (find the exact Kconfig/API in the User Guide — do not assume symbol names), max level 4, SoftAP password = `net_psk`.
- SAFR emitter: HEARTBEAT every 15 s (`LAYER` = Mesh-Lite level, `PARENT_MAC` = parent BSSID; for the root, `PARENT_MAC` = board MAC, `RSSI_TO_PARENT` = RSSI to the board), TOPOLOGY every 60 s and on child change, `NAME_ANNOUNCE` once after boot. Button short press → `EVENT ALERT MANUAL_TEST` with `F_ACK_REQ`. Button double press (or a serial console command if easier) → `EVENT ALARM SMOKE_ALARM` with `F_ACK_REQ`, re-announced every 60 s with `F_RETX` until a `RESET` command arrives (blueprint §6 / spec §7.2).
- Uplink transport: if this node is root → TCP client to 192.168.4.1:5340, reconnect forever with 2 s backoff; else → `esp_mesh_lite_send_raw_msg_to_root()` (or the raw-message API the User Guide names). The root receives children's raw messages and writes them to the TCP socket unchanged.
- Downlink transport: root reads frames from TCP and broadcasts them to its children with the raw broadcast-to-child API; **verify whether Mesh-Lite propagates that broadcast beyond one level**; if not, every node re-broadcasts to its own children, deduping by `(SRC_MAC, MSG_ID)` for 30 s. Each node acts only on frames whose `DST_MAC` is its own or broadcast.
- Downlink handling: `IDENTIFY` → LED blue for N s; `TEST` → emit MANUAL_TEST; `RESET` → stop alarm re-announce; `TIME_SYNC` → set RTC; ACK every frame with `F_ACK_REQ` addressed to this node.
- **Never** use `esp_mesh_lite_try_sending_msg()` for SAFR. Retries are SAFR's own (fresh `MSG_CTR`, same `MSG_ID`, 3 × 2 s).

---

## 5. Provisioning HTTP contract (replaces the current `server.js`; update the mock to match)

Setup network: `SIOT-SETUP-<id>`, WPA2, password = `pop`. Server: `http://192.168.4.1`.

| Endpoint | Request | Response |
|---|---|---|
| `GET /info` | — | `200 {id, mac, model, fw, state, nonce}` — `nonce` = 16 random bytes hex, regenerated per `/info` |
| `POST /identify` | `{id, proof}` with `proof = hex(HMAC-SHA256(key = pop, msg = nonce))` | `200 {ok:true}` or `403 {ok:false, error:"proof_mismatch"}` |
| `POST /provision` | `{envelope, name, zone, epoch}` — `envelope = base64(nonce2 ‖ AES-128-CCM(key = HKDF-SHA256(ikm = pop, salt = nonce, info = "siot-prov-v1", 16 bytes), nonce = nonce2 (12 bytes), aad = id, plaintext = code_json) ‖ tag16)`; `code_json = {system_id, net_ssid, net_psk, safr_psk_hex, channel, mesh_id}` | `202 {ok:true}`; `409 not_identified`; `400 bad_envelope` |
| `POST /enroll` (board only) | `[{mac, id, name, zone}]` | `200 {ok:true, count}` |
| `GET /status` | — | `200 {state, detail}`; `state ∈ idle, identified, stored, joining, online, failed` |

`name` ≤ 32 bytes UTF-8, `zone` ≤ 16 bytes. `stored` = code saved, no installation network in reach yet; `joining` = network seen, Mesh-Lite connecting; `online` = first frame ACKed by the board.

---

## 6. App changes (Flutter, `mobile/sempreiot_central_app`) — only these

1. **Installation entity** (`features/installation/`): create/generate the code (`SYSTEM_ID` random u16 ≠ 0, `NET_SSID = "SIOT-" + hex4`, `NET_PSK` 16 random alnum, `SAFR_PSK` 16 random bytes, `CHANNEL` ∈ {1,6,11}, `MESH_LITE_ID` derived), stored encrypted with `flutter_secure_storage`; show as QR; scan from QR. Zones list per installation.
2. **Provisioning wizard** (`features/provisioning/`): steps become *scan sticker → name + zone → connecting → identify → provision → result*. Replace the "open Wi-Fi settings" step with programmatic join (`WifiNetworkSpecifier` on Android via a small platform channel or a maintained plugin; iOS only if the phone in §0 is iOS). `DeviceApService` implements §5 (HMAC proof, HKDF + CCM envelope — reuse `safr_crypto.dart`'s CCM). For the board's sticker, also send `/enroll`. Result states `stored` / `online`; delete `resultAssumed`.
3. **CENTRAL mode**: on serial link-up send `GET_INSTALLATION`; store the reply; registry (`MeshDevices`) gains `state ∈ enrolled | online | missing | retired` and `name/zone` from `NAME_ANNOUNCE` or the enrolled list; the Rede/Eventos screens show names. Parse the two new message types in `safr_v2_payloads.dart` and `safr_parser.dart`; add round-trip tests for them.
4. Keep everything else as is. The existing SAFR pipeline, latching, supervision, ACK/retry and the Appendix A vector tests must keep passing (`flutter test`).

Do not touch: auth, access relations, MQTT/cloud, lambdas, the storage screen, theme.

---

## 7. Test script (run in this order, record in `RESULTS.md`)

1. **Flash factory NVS** on all three with `tools/make_sticker.py` (three different `id`/`pop`); print the three QR PNGs. Power up → all three white-blink and expose `SIOT-SETUP-<id>`.
2. **Case A setup** from the phone app: create installation; provision node B (name "Sirene 1", zone "Térreo"), node C ("Sirene 2", "1º andar"), then board A (installation name) — the app sends `/enroll` with B and C. Each ends in `stored`. Record time per unit.
3. **Bring-up**: plug board A to the tablet. Expected within 2 min: tablet shows mesh connected; B and C online **with their names**; one of them at layer 1 (root), the other at layer 2. Record: time to first frame from each node, which one is root, RSSI values.
4. **Traffic**: run 30 min. Record: heartbeats received vs expected per node (from `serial_logs` counters), CRC/auth failures (must be 0), LINK_CHECK confirmations.
5. **Downlink**: from the Rede tab, IDENTIFY node C (level 2) → its LED blinks blue; TEST → MANUAL_TEST event appears; measure round-trip.
6. **Alarm at level 2**: double-press on C → ALARM latched on the tablet; record smoke-button-to-screen time (target ≤ 10 s, expect ≪ 1 s); confirm re-announce every 60 s appears as a single feed entry; RESET clears the latch only after the ACK.
7. **Failover**: cut power to the root. Record with `tools/failover_timer.py`: time until the other node's heartbeat arrives with `LAYER = 1`; time until "device missing" trouble for the dead node (expect ≈ 45 s). Restore power: dead node rejoins (record level and time). Repeat 5 times; report min/median/max.
8. **Alarm during failover**: cut the root, immediately double-press the survivor → it must become root and deliver the ALARM; record delay.
9. **Factory reset**: hold C's button 5 s → white solid → white blink; tablet shows C missing; re-provision C with the same name; it returns online.

Pass criteria: step 3 ≤ 2 min; step 4 zero CRC/auth failures and ≥ 99 % heartbeats; step 6 ≤ 10 s; step 7 median ≤ 60 s and max ≤ 120 s, no alarm lost in step 8; setup ≤ 30 s per unit and no "assumed" anywhere.

---

## 8. `RESULTS.md` template

```
# POC round 1 results — <date>
Hardware: <from §0>   IDF: <ver>   mesh_lite: <ver>   app commit: <sha>
| Step | Measurement | Value | Pass? | Notes |
...
Root election observed: <which node, why (RSSI)>
Failover runs (s): [..,..,..,..,..]  median: .. max: ..
Open problems / surprises:
Recommendation for round 2 (ESP-NOW leaf):
```

---

## 9. Rules for you, the implementing session

- Do not change the architecture. If Mesh-Lite lacks something this brief assumes (e.g. broadcast propagation, a Kconfig symbol), implement the workaround the brief names or STOP and ask; do not swap libraries or move the root to the board.
- Do not edit `docs/safr/protocol-safr-v3.md` beyond adding the v3.1 items named here (`GET_INSTALLATION` 0x10, `SET_INSTALLATION` 0x11, `INSTALLATION` 0x09, `NAME_ANNOUNCE` 0x0A, LEN ≤ 250). Keep Appendix A vectors valid.
- Pin the Mesh-Lite version in `idf_component.yml`; `idf.py set-target` per §0.
- `CONFIG_ESP_CONSOLE_NONE=y` on the board; logs on the nodes may use the console, never the SAFR port.
- Small commits per step of §7; update `RESULTS.md` as you go, not at the end.
- When in doubt about a number (timeouts, intervals), use the value in `docs/safr/protocol-safr-v3.md`; if it isn't there, use the blueprint; if it isn't there either, STOP and ask.
- Report back with `RESULTS.md` filled and a list of what in the app you changed, file by file.
