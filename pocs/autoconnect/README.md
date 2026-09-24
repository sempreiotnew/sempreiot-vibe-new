# autoconnect — setup-network provisioning POC

Implements the **setup-network provisioning cycle** (`siot_prov`,
`docs/others/system-blueprint-v1.md` §2–§3) as real ESP-IDF firmware: a unit with no
installation code raises `SIOT-SETUP-<id>` and answers the HTTP contract in
`pocs/POC-BRIEF.md` §5, exactly like `mocked-device-autoconnect/server.js`
simulates on a laptop — this is the real thing, meant to run on hardware.

**Layout note:** the actual `siot_prov` implementation
(`prov_store/prov_http/prov_crypto/wifi_softap`, plus the
`SIOT_ROLE`/`SIOT_FACTORY_*` Kconfig menu) now lives in the shared component
`pocs/components/siot_prov/`, so `pocs/board` and `pocs/node` can reuse it
too. This project (`autoconnect`) is now a thin `main/autoconnect.c` that
just `REQUIRES siot_prov` and wires it up — behavior is unchanged from
before the split. `pocs/autoconnect/CMakeLists.txt` adds
`pocs/components/` to `EXTRA_COMPONENT_DIRS` so the local component
resolves without a component-registry entry.

## Scope

**In:** SoftAP bring-up, the five HTTP endpoints (`/info`, `/identify`,
`/provision`, `/enroll`, `/status`), the HKDF/HMAC/CCM crypto, NVS storage of
the factory identity and the installation code.

**Out (belongs to `pocs/board` / `pocs/node`, not built here):** normal-mode
behaviour after provisioning — raising the installation AP (board) or joining
Mesh-Lite (node), the SAFR uplink/downlink, LEDs/button (reuse
`pocs/patinha` when that work starts). `on_provisioned()` in `autoconnect.c`
just logs and reboots — that callback is the seam where `pocs/board` /
`pocs/node` plug in their real normal-mode logic.

## Hardware facts assumed (POC-BRIEF.md §0 was not filled in for this piece)

- **Chip:** `esp32s3`, inferred from `pocs/patinha` (the sibling POC this
  project's conventions are meant to match) and pinned in
  `sdkconfig.defaults`.
- **ESP-IDF version:** v5.5.2, per `pocs/patinha/README.md`
  (`source ~/.espressif/tools/activate_idf_v5.5.2.sh`).
- **mesh_lite version:** not needed here (no Mesh-Lite dependency in this
  component).
- Real PCB vs. dev kit, and the exact tablet/phone hardware, don't affect
  this component's code.

**If the real chip differs, change `CONFIG_IDF_TARGET` in
`sdkconfig.defaults` and re-run `idf.py set-target` before building — nothing
else here is chip-specific.**

## Interim shortcut — flag for reconciliation

`pocs/POC-BRIEF.md` §4.1 says the factory NVS namespace `siot_fact` (`id`,
`pop`) is written once by `tools/make_sticker.py` via `nvs_partition_gen` and
**never generated at runtime**. That tool doesn't exist in this repo yet, so
`pocs/components/siot_prov/prov_store.c` falls back to two Kconfig values
(`SIOT_FACTORY_DEV_ID` / `SIOT_FACTORY_POP`, menu "SIOT Provisioning
(autoconnect POC)") only when `siot_fact` is empty in NVS. This exists solely
to let this POC run on a bare dev kit before `make_sticker.py` is built —
**remove the fallback once the factory-partition flow exists**, so an
unprovisioned factory identity is a hard failure again, matching the
blueprint.

## Building

```bash
source ~/.espressif/tools/activate_idf_v5.5.2.sh   # or your IDF v5.x env
cd pocs/autoconnect
idf.py set-target esp32s3
idf.py menuconfig   # set SIOT_ROLE to board for the board unit; set
                     # SIOT_DEV_MODEL to "SIOT-BOARD-01" for the board too
                     # (pocs/APP-BRIEF.md §5 step 2 detects that prefix)
idf.py build flash monitor
```

No `idf.py` / ESP-IDF toolchain was available in the environment this code
was written in, so **this has not been compiled**. Build it as the first
step before flashing.

## Verifying against the app / mock

`mocked-device-autoconnect/crypto-helpers.js` implements the identical
HKDF/HMAC/CCM derivation in Node, and the Dart app implements it under
`lib/features/provisioning/domain/`. All three are meant to agree on the same
`vectors.json` (`pop`, `nonce`, `nonce2`, `code_json`, expected `proof`,
expected `envelope`) — once that file exists, add a small `idf.py` unit test
(or a host-side test using the `pocs/components/siot_prov/prov_crypto.*`
sources compiled for the host) asserting
`siot_crypto_proof`/`siot_crypto_derive_key` reproduce the same vectors
bit-for-bit.

## Endpoints implemented (`pocs/components/siot_prov/prov_http.c`)

| Endpoint | Notes |
|---|---|
| `GET /info` | Fresh 16-byte random nonce every call; the last one is what `/identify` and `/provision` check against. |
| `POST /identify` | `proof = hex(HMAC-SHA256(pop, nonce))`, mbedtls `mbedtls_md_hmac`. 403 `proof_mismatch` otherwise. |
| `POST /provision` | `envelope = base64(nonce2(12) ‖ AES-128-CCM(key, nonce2, aad=id, code_json) ‖ tag(16))`, `key = HKDF-SHA256(pop, nonce, "siot-prov-v1", 16)` via `mbedtls_hkdf`. On success, stores the code + `name`/`zone` in NVS `siot_inst` and replies `202`; `409 not_identified` before `/identify`; `400 bad_envelope` on any decode/decrypt/parse failure. |
| `POST /enroll` | `404 not_a_board` unless `SIOT_ROLE_BOARD`; otherwise counts the array and replies `{ok:true, count}`. Round 1 does not persist the enrolled list beyond logging it — extend `prov_store.c` if the board needs to serve it back over SAFR later. |
| `GET /status` | Reports `idle/identified/stored/joining/online/failed`. This POC only ever reaches `stored` (see Scope) — `joining/online/failed` are defined in `prov_types.h` for `pocs/board`/`pocs/node` to use once they own normal-mode. |

No `/reset` — that is a `mocked-device-autoconnect`-only dev helper, not part
of the firmware contract (blueprint: a real unit only leaves setup mode via a
successful `/provision` or the 5 s factory-reset button hold).
