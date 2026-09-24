# APP round 1 — task brief for the implementing session (Flutter app)

*Paste the block below as the first message of the session, then let it read this file.*

> You are implementing the app side of POC round 1 for the SempreIoT fire alarm system, in the Flutter project `mobile/sempreiot_central_app`. Your contract is `pocs/APP-BRIEF.md` — read it fully first, then the files it lists in order. Do not re-decide the architecture (it is in `docs/others/system-blueprint-v1.md`). Where the brief says STOP, stop and ask Talles. Work in small commits, run `flutter test` before every commit, and finish by reporting file-by-file what you changed.

---

## 0. Facts to fill in before starting


| Fact                                                    | Value                                          |
| ------------------------------------------------------- | ---------------------------------------------- |
| Phone used for installer flows                          | `<Android version / iOS version>`              |
| Tablet (CENTRAL mode)                                   | `<Android version; camera yes/no>`             |
| Flutter / Dart versions                                 | `<flutter --version>`                          |
| Is the firmware from `pocs/POC-BRIEF.md` available yet? | `<yes: board/node flashed / no: use the mock>` |


The mock (`mocked-device-autoconnect/`, which you update first in §3) exists only so that app work can proceed **in parallel** with the firmware session and so the crypto/contract can be unit-tested against shared vectors. It is **not** how the POC is validated. **The POC is validated only in §11, with the real firmware from `pocs/POC-BRIEF.md` on the three real boards and the real tablet.** Do not report the app work as done before §11 has run. **If any cell is `<…>`: STOP and ask.**

---

## 1. Read in this order

1. `docs/others/system-blueprint-v1.md` — §0 vocabulary, §1 rules, §3 installation (Case A and B), §9.3–9.4 (contract and app work). Non-negotiable.
2. `pocs/POC-BRIEF.md` §5 (provisioning HTTP contract) and §4.2 (the board's `GET_INSTALLATION` / `INSTALLATION` / `NAME_ANNOUNCE` frames). The firmware session implements the other side of exactly these bytes.
3. `docs/others/app-sempreiot-central.md` — the map of the current code. You will touch §7 (provisioning), §5 (SAFR pipeline: two new message types, registry states) and §8 (screens showing names). Everything else stays.
4. `docs/safr/protocol-safr-v3.md` — frame layout, CCM, CRC, message types. Appendix A vectors must keep passing.
5. `mobile/sempreiot_central_app/CLAUDE.md` — project conventions (note: it mentions AppSync/go_router which the code does not use; follow the code, not that file).
6. `mocked-device-autoconnect/server.js` + `README.md` — the current mock; you replace its contract.
7. Code to read before editing: `lib/features/provisioning/*`*, `lib/features/central/domain/safr/**`, `lib/features/central/application/{safr_ingest_provider,safr_downlink_provider,serial_link_provider,supervision_provider,topology_provider,device_events_provider}.dart`, `lib/core/database/app_database.dart`, `lib/features/central/presentation/screens/{topology_screen,events_screen}.dart`, `lib/main.dart`, `test/**`.

---

## 2. Scope

**In:** installation entity; provisioning wizard against the new contract with programmatic Wi-Fi join and name/zone; CENTRAL-mode installation read-out and device registry states with names; SAFR v3.1 codec additions with tests; mock server updated; optional Case B (`SET_INSTALLATION`).

**Out (do not touch):** auth/Cognito, access relations, MQTT/cloud, lambdas, storage screen, theme, PIN gates, the events/latching/journal logic, `SerialPackets` forensics. No dependency upgrades beyond what §4 needs.

---

## 3. Step 1 — update the mock first (`mocked-device-autoconnect/server.js`)

Make the mock implement `pocs/POC-BRIEF.md` §5 exactly, so the wizard can be built and integration-tested without hardware:

- Env: `DEVICE_ID`, `POP` (replaces `SIGNATURE`), `MAC`, `MODEL`, `ROLE` (`node` | `board`), `JOIN_RESULT` (`stored` | `online` | `failed` | `drop`), `JOIN_DELAY_MS`, `PORT`.
- `GET /info` → `{id, mac, model, fw, state, nonce}` with a fresh 16-byte hex nonce each call (keep the last one for `/identify`).
- `POST /identify {id, proof}` → verify `proof == hex(HMAC-SHA256(POP, nonce))`; 403 `proof_mismatch` otherwise.
- `POST /provision {envelope, name, zone, epoch}` → decode `envelope` (base64 of `nonce2(12) ‖ ciphertext ‖ tag(16)`), derive `key = HKDF-SHA256(ikm=POP, salt=nonce(from /info, raw bytes), info="siot-prov-v1", L=16)`, decrypt AES-128-CCM with `aad = id` (UTF-8), tag 16; on success store the JSON code, log it, respond 202; else 400 `bad_envelope`. Node's `crypto` module has HKDF and `aes-128-ccm` with `authTagLength: 16`.
- `POST /enroll` (only when `ROLE=board`) → store the list, respond `{ok:true, count}`.
- `GET /status` → `{state, detail}` walking `identified → stored → joining → online|failed` per `JOIN_RESULT`; `drop` = go silent after the 202 (keep this behaviour — the wizard must still handle it, but now the result is `stored`, never "assumed").
- `POST /reset` stays as a dev helper. Keep CORS. Update `README.md` (it declares itself the firmware contract — keep that true).

Add `npm test` with a script that exercises the happy path using the same HKDF/HMAC/CCM code the app will use (a Node port of the app's derivation, so both sides are checked against the same vectors). Commit the test vectors (`pop`, `nonce`, `nonce2`, `code_json`, expected `proof`, expected `envelope`) into `mocked-device-autoconnect/vectors.json`; the Dart tests in §7 must load the same file.

---

## 4. Step 2 — installation entity (`lib/features/installation/`)

Domain `Installation { systemId (int, 1..65535), netSsid ("SIOT-" + 4 hex upper), netPsk (16 alnum), safrPsk (16 bytes), channel (1|6|11), meshLiteId (derived: systemId & 0xFF, or as the firmware session defines — read` pocs/POC-BRIEF.md`; if undefined there, use` systemId & 0xFF `and say so in the report), name, createdAt, zones (List<String>), enrolled (List<EnrolledUnit{mac,id,name,zone,state}>) }`.

- Generation with `Random.secure()`. `systemId` never 0. Channel: default 6 (the phone cannot scan channels reliably in Flutter; make it editable in the installation screen).
- Storage: `flutter_secure_storage` for `netPsk`/`safrPsk`; the rest in Drift (new table `Installations`, one row active) or SharedPreferences — Drift preferred, schema v7 with migration.
- QR: `installation:v1:` + base64url of the JSON `{sid, ssid, psk, key, ch, mid, name}`; show with `qr_flutter` (already a dependency); scan with `mobile_scanner` (already a dependency). Screen: `InstallationScreen` (create / show QR / scan QR / edit zones / list enrolled units with state).
- Drawer entry "Instalação" in APP mode and in CENTRAL mode.

---

## 5. Step 3 — provisioning wizard (`lib/features/provisioning/`)

Rewrite `ProvisioningWizardNotifier` and the step widgets to this sequence:

1. `scan` — scan the sticker QR `{"id":..,"mac":..,"pop":..}` (manual entry allowed). Replace `DeviceQrPayload` fields accordingly.
2. `nameZone` — **mandatory** name (≤ 32 bytes UTF-8, validate byte length) and zone (dropdown from the installation's zones + "new zone"). If the sticker is a board (model starts with `SIOT-BOARD`, or the user toggles "this is the board"), the name is the installation name and no zone.
3. `connecting` — programmatic join to `SIOT-SETUP-<id>` with password `pop` (see §6). Show the SSID; offer "open Wi-Fi settings" only as a fallback button if the join API fails.
4. `identifying` — `GET /info` (poll every 2 s, timeout 3 s, up to 30 s) → `POST /identify` with `proof`.
5. `provisioning` — build the envelope (§7), `POST /provision {envelope, name, zone, epoch = now UTC seconds}`; if board: also `POST /enroll` with the installation's enrolled list.
6. `waiting` — poll `GET /status` every 2 s: `stored` → `resultStored`; `online` → `resultOnline`; `failed` → `resultFailed`; 4 consecutive unreachable polls → `resultStored` (the device dropped its setup network after saving — this is expected, never "assumed").
7. `result`* — on `stored`/`online`: add/update the unit in `installation.enrolled` with `state = enrolled` (or `online`), release the Wi-Fi binding, offer "next unit". On `failed`: back to `connecting` with the error.

Delete `resultAssumed`, `SelectCentralStep`, the `centralId`/`networkReady` fields, and the `SEMPREIOT-<ID>` SSID string. Keep the phase header widget and `WizardButtons`. `DeviceApService` becomes injectable (constructor takes base URL + an `http.Client`) so tests can stub it.

---

## 6. Programmatic Wi-Fi join

Android (primary): add a platform channel `com.sempreiot.central/wifi` in `android/app/src/main/kotlin/.../MainActivity.kt`: `connect(ssid, password)` → `ConnectivityManager.requestNetwork` with a `NetworkRequest` that adds `TRANSPORT_WIFI`, **removes** `NET_CAPABILITY_INTERNET` (so Android does not reject a network without internet), and sets a `WifiNetworkSpecifier` (`setSsid`, `setWpa2Passphrase`); on `onAvailable` call `bindProcessToNetwork(network)` so Dart's `http` goes through the device network; `disconnect()` → `unregisterNetworkCallback` + `bindProcessToNetwork(null)`. Requires `ACCESS_FINE_LOCATION` at runtime on Android 10–12 (use `permission_handler`, already a dependency? if not, add it) and `NEARBY_WIFI_DEVICES` on 13+. Also `CHANGE_NETWORK_STATE`. Document the manifest changes.

iOS: only if the phone in §0 is iOS — `NEHotspotConfiguration` via a small Swift channel, same interface.

Web: provisioning stays hidden (mixed content), as today.

Provide a Dart `WifiJoinService` interface with `connect/disconnect` and a fake for tests.

---

## 7. Crypto for the contract (Dart)

- `proof = hex(HMAC-SHA256(key = utf8(pop), msg = bytesFromHex(nonce)))` — `package:crypto`.
- `key = HKDF-SHA256(ikm = utf8(pop), salt = bytesFromHex(nonce), info = utf8("siot-prov-v1"), length 16)` — implement HKDF with `package:crypto` HMAC (extract + one expand block); add a unit test against RFC 5869 test case 1.
- `envelope = base64(nonce2(12 random) ‖ CCM_encrypt(key, nonce2, aad = utf8(id), plaintext = utf8(jsonEncode(code))) ‖ tag16)` — reuse the PointyCastle `CCMBlockCipher` setup already in `lib/features/central/domain/safr/safr_crypto.dart` (factor the raw CCM call into a shared helper rather than duplicating it).
- Tests: `test/provisioning/prov_crypto_test.dart` loads `mocked-device-autoconnect/vectors.json` and asserts `proof` and `envelope` byte-for-byte (envelope with the vector's fixed `nonce2`).

---

## 8. Step 4 — CENTRAL mode: installation read-out and registry states

- **SAFR v3.1 codec** (`lib/features/central/domain/safr/safr_v2_payloads.dart`, `safr_encoder.dart`, `safr_parser.dart`):
  - Downlink `COMMAND` CMD `0x10 GET_INSTALLATION` (no args) and `0x11 SET_INSTALLATION` (args = `system_id u16 ‖ channel u8 ‖ mesh_id u8 ‖ ssid_len u8 ‖ ssid ‖ psk_len u8 ‖ psk ‖ safr_psk 16 ‖ name_len u8 ‖ name`) — SET is Case B, implement encode + test even if the UI is optional. *(2026-09-24: this layout was adopted by protocol v3.2 §7.6; SET is sent on the pop-keyed setup channel, spec §3.1. The INSTALLATION `state` byte and NAME_ANNOUNCE `role` byte below are superseded by spec §7.10–§7.12 — INSTALLATION is unchanged, DEVICE_TABLE carries state, NAME_ANNOUNCE's role is an optional trailing byte.)*
  - Uplink `MSG_TYPE 0x09 INSTALLATION`: `system_id u16 ‖ channel u8 ‖ mesh_id u8 ‖ ssid_len u8 ‖ ssid ‖ name_len u8 ‖ name ‖ count u8 ‖ count × (mac 6 ‖ state u8 ‖ name_len u8 ‖ name ‖ zone_len u8 ‖ zone)`. Never contains PSKs.
  - Uplink `MSG_TYPE 0x0A NAME_ANNOUNCE`: `name_len u8 ‖ name ‖ zone_len u8 ‖ zone ‖ role u8 (0 board,1 AC device,2 battery detector)`.
  - Enforce `LEN ≤ 250` in the encoder. Round-trip tests for all three in `test/safr/safr_v31_roundtrip_test.dart`; extend `safr_v3_roundtrip_test.dart` dispatch cases.
- **Downlink provider** (`safr_downlink_provider.dart`): on link-up, after `TIME_SYNC` and before `EVENT_LOG_REQ`, send `GET_INSTALLATION` (tracked, ACK expected); store the reply into the `Installations` row (CENTRAL mode keeps the same table; PSKs absent).
- **Registry** (`app_database.dart` `MeshDevices`): add `name` (exists), `zone`, `state` (`enrolled|online|missing|retired`), `role`. Migration v7. `SafrIngestService`: on `INSTALLATION` → upsert every enrolled unit with `state = enrolled` if not already `online`; on `NAME_ANNOUNCE` → set `name/zone/role`; on any authenticated frame → `state = online`. `SupervisionNotifier`: `missing` when offline, back to `online` on any frame; never touch `retired`. "Retire" action on the node sheet in `topology_screen.dart` sets `retired` and hides the unit from supervision.
- **Layer-0 shim**: the board announces itself as `LAYER = 0`, `NODE_ROLE = 0`; keep `meshLinkStateProvider` logic as is (it already keys on layer 0 / role 0). AC devices arrive with `LAYER ≥ 1`.
- **UI**: `TopologyScreen` node sheet and `EventsScreen` cards show `name` (fallback MAC) and `zone`; badge per `state`. Dashboard counters (`_CentralDashboard`) read real numbers: enrolled / online / missing from the registry. Remove the hard-coded 78 % / 32 °C gadgets or feed them from the board's HEARTBEAT (battery %, temp) — either is acceptable, say which you did.
- **Case B (optional)**: `InstallationScreen` in CENTRAL mode: "Criar instalação" → generate → `SET_INSTALLATION` → wait for ACK → show QR. Only after everything above is green.

---

## 9. Tests to add or update

- `test/provisioning/prov_crypto_test.dart` (vectors), `test/provisioning/wizard_notifier_test.dart` (fake `DeviceApService` + fake `WifiJoinService`: happy `stored`, happy `online`, proof mismatch, bad envelope, drop → `stored`, board path sends `/enroll`).
- `test/provisioning_wizard_integration_test.dart` rewritten against the new mock (`DEVICE_AP_URL`), including `ROLE=board`.
- `test/safr/safr_v31_roundtrip_test.dart`; `safr_ingest_test.dart` gains: `INSTALLATION` seeds `enrolled`, `NAME_ANNOUNCE` names a unit, first frame flips to `online`, supervision flips to `missing` and back.
- All existing tests must pass unchanged, including `safr_v3_vectors_test.dart` and `safr_v3_captured_test.dart`.

---

## 10. Rules for you

- Do not change the wire format of existing SAFR messages. New types only, numbered as above; the firmware session uses the same numbers.
- Do not send `net_psk` or `safr_psk` over USB or MQTT.
- Do not reintroduce "assumed". Do not reintroduce "open Wi-Fi settings" as a normal step.
- Do not touch the modules listed as out of scope; if a change there seems unavoidable, STOP and explain.
- `flutter analyze` clean, `flutter test` green before each commit. Update `docs/others/app-sempreiot-central.md` §2 tables, §5 table and §7 at the end so the map stays true.
- Finish with a report: files changed, migrations added, manifest/permission changes, what was left optional, and anything in `pocs/POC-BRIEF.md` you needed to interpret (so the firmware side can be aligned).

---

## 11. Validation with the real firmware — mandatory, the POC is not done without it

When the firmware session reports that `pocs/board` and `pocs/node` are flashed on the three boards:

1. Flash the app in CENTRAL mode on the tablet and in APP mode on the phone (`--dart-define=APP_MODE=central` / default).
2. Run `pocs/POC-BRIEF.md` §7 steps 1–9 together with the firmware session, using the real setup networks (no mock, no `DEVICE_AP_URL`).
3. Every measurement goes into `pocs/RESULTS.md`; every app-side defect found is fixed in this session and re-run.
4. The round is complete only when the pass criteria in `pocs/POC-BRIEF.md` §7 are met with the real boards. Report app-side and firmware-side interpretations that had to be reconciled during this step, so both briefs can be corrected.

