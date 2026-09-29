# CLAUDE.md — SempreIoT repo rules (all sessions, all subfolders)

Applies to every Claude session working anywhere in this repo. The Flutter app has its own
additional rules in `mobile/sempreiot_central_app/CLAUDE.md`.

---

## 🚨 CRITICAL — ESP-IDF firmware (firmware/, pocs/, mocked-device/, any `idf.py` project)

**The ONLY toolchain is ESP-IDF v5.5.2.** It is loaded by:

```bash
source ~/.espressif/tools/activate_idf_v5.5.2.sh
```

Run that in every shell before any `idf.py` command (`build`, `set-target`, `flash`, `monitor`,
`menuconfig`, `reconfigure`). It sets `IDF_PATH` and puts `idf.py` and the toolchains on `PATH`.

**Rules — non-negotiable:**

1. **Never guess an API.** Every ESP-IDF function, struct field, enum, Kconfig symbol or macro you
   use MUST exist in ESP-IDF **v5.5.2** exactly. Before using anything you are not 100% sure of,
   grep the real header on disk:
   - ESP-IDF itself: `grep -rn "<symbol>" "$IDF_PATH/components/<component>/include"`
   - Managed components (Mesh-Lite etc.): `grep -rn "<symbol>" <project>/managed_components/*/include`
     — e.g. `pocs/node/managed_components/espressif__mesh_lite/include/esp_mesh_lite*.h`
   If it is not in a header, it does not exist. Do not invent it, do not "assume" it, do not leave a
   `TODO(verify)` and move on. Read the header and use the real signature.
2. **Do not use APIs from other IDF versions.** v4.x-era names (e.g. `tcpip_adapter_*`,
   `esp_event_loop_init`, legacy `driver/adc.h` / `driver/i2c.h` / `driver/rmt.h` / `driver/timer.h`
   / `driver/pcnt.h`) are removed or deprecated in 5.5.2; use the 5.x drivers
   (`esp_adc/adc_oneshot.h`, `driver/i2c_master.h`, `driver/rmt_tx.h`, `driver/gptimer.h`,
   `driver/pulse_cnt.h`, `esp_netif`). When in doubt, grep `$IDF_PATH/components`.
3. **Code is not done until `idf.py build` passes.** After every firmware change:
   ```bash
   source ~/.espressif/tools/activate_idf_v5.5.2.sh
   cd firmware/apps/<app>   # or pocs/<project>
   idf.py build
   ```
   Fix every error and every warning you introduced. Never hand back code with a "Not compiled" note
   or a README saying "expect compile errors" — if you cannot run the build in your environment,
   say so explicitly at the top of your report and list exactly which symbols you could not verify
   against the headers; but first try, the toolchain is installed on this machine.
4. **Target chip:** take it from the project's `sdkconfig` (`CONFIG_IDF_TARGET`) / `idf.py set-target`;
   do not change the target. If a project has no sdkconfig yet, STOP and ask which chip.
5. **Component versions are pinned by `dependencies.lock`** in each project (Mesh-Lite is
   `espressif/mesh_lite 1.0.2`). The headers in `managed_components/` are the exact API for that
   version — they beat any web page, README summary, or memory of the docs.
6. **Docs beat guesses; headers beat docs.** Order of truth for any firmware question:
   header on disk → `$IDF_PATH/examples/` and `managed_components/*/examples` → official docs for
   v5.5.2 (`https://docs.espressif.com/projects/esp-idf/en/v5.5.2/`) → nothing else.

---

## 🚨 CRITICAL — one LED language, firmware and app

Every unit (board, node, leaf) speaks the **same LED language**, and the tablet app **mirrors it
exactly** on screen. Source of truth: `firmware/components/ui/siot_ui_led` (`siot_ui_led.h` /
`siot_ui_led.c`), catalogued in `docs/sempreiot-system-reference.md` §3.7 row 7.7.

**Rules — non-negotiable:**

1. **One meaning per colour, on every device.** white blink = setup · white breathe = finding the
   network · blue = a frame this unit sent (100 ms background, 500 ms message) · **cyan = the
   central confirmed this unit's frame (the ONLY "confirmed" colour — never green)** · green flash =
   root node · magenta flash = board · red = alarm / fault / nothing came back · green / yellow / red
   blinks = link quality in a survey · blue blink = IDENTIFY. Do not give a device its own colour
   for something another device already signals.
2. **Go through `siot_ui_led`.** Post the bus event (`SIOT_EVT_ACK_RECEIVED`, `SIOT_EVT_SAFR_TX`,
   `SIOT_EVT_STATE_CHANGED`, …) and let `siot_ui_led` choose the colour and the duration. Call
   `siot_ui_led_pulse` / `_set` directly only for something no event covers, and with the
   `SIOT_LED_*_MS` constants — never a private number.
3. **A firmware LED change is not done until the app shows the same thing.** In the same change,
   update `mobile/sempreiot_central_app/lib/features/central/domain/led/led_language.dart`
   (colours, durations, queue), `.../application/device_led_provider.dart` (which frame lights
   which unit) and `test/central/device_led_test.dart`, then run `flutter test
   test/central/device_led_test.dart`. Same for the packet colours on the Rede map.
4. **And the docs:** reference §3.7 row 7.7, protocol §12.8 (leafs), `docs/devices/*.md` LED tables,
   and the installer texts in the app that name a colour (provisioning wizard, "Entrar pela placa").
5. What never crosses the wire (survey blinks, setup, button hold) cannot be mirrored; say so in
   `device_led_provider.dart`'s header instead of guessing.

---

## Database tables — keep the reference in sync

The tablet app's local database (`mobile/sempreiot_central_app/lib/core/database/app_database.dart`,
Drift) is catalogued in **`docs/sempreiot-system-reference.md` §3.6.1**. Whenever a table is
**created, removed or renamed** (and when a column that changes what a table means is added),
update that section in the same change: table, key, what it holds, who writes/reads it, retention.
A schema change is not done until the reference says the same thing as the code.

---

## Repo map

- `docs/sempreiot-system-reference.md` — **start here**: functionality catalogue, status, customer
  numbers, index of every doc and the order of authority.
- `docs/safr/protocol-safr-v3.md` — the wire format. Single source of truth for anything on the wire.
- `docs/others/system-blueprint-v1.md` — rules, vocabulary, installation, network formation, operation.
  Wins over every other doc except the protocol. `docs/others/app-sempreiot-central.md` — the Flutter
  app as it is.
- `docs/ota/` — OTA + production blueprint, secure-signed-firmware how-to.
- `docs/spec/` — PCB GPIO maps (central, detector).
- `docs/phases-development/firmware-phase1-network-brief_3.md` — what Phase 1 of the product firmware
  builds, the `firmware/` tree, exit checklist, open items, implementation order.
- `firmware/` — the product firmware (all images: `apps/board`, `apps/node`, later `apps/leaf`), layered
  components under `firmware/components/{core,platform,net,ui,features}`. Layout and rules: brief §2.
- `pocs/POC-BRIEF.md` — the contract for the round-1 POC; `pocs/board`, `pocs/node`,
  `pocs/components/{safr,siot_prov,siot_led}` are the POC firmware projects — **reference only once
  `firmware/` exists: copy from them, do not modify them.**
- `pocs/patinha/` — reference GPIO/LED/button code (copy, do not modify).
- `mocked-device/` — reference SAFR/root-duties C implementation (copy, do not modify).
- `tools/` — `make_sticker.py` (factory identity + QR), `failover_timer.py`, `capture-safr.sh`.
- `mobile/sempreiot_central_app/` — Flutter app; see its own `CLAUDE.md`.
- `lambda/` — AWS lambdas (out of scope unless asked).
