# firmware/ — SempreIoT product firmware

All firmware images live here. Layout, layering rules and the implementation order are in
`docs/phases-development/firmware-phase1-network-brief_3.md` §2 / §15; this file is the short version.

```
apps/            one folder per image — THIN: app_main.c, sdkconfig.defaults, partitions_*.csv, idf_component.yml
  board/         sempreiot-board  (8 MB) — control unit: installation AP, TCP bridge, serial to tablet, root duties
  node/          sempreiot-node   (4 MB) — every AC device type (siren, I/O, AC detector, repeater) in one image
  (leaf/)        Phase 2 — battery detector (ESP-NOW, deep sleep)
components/      ALL the code, shared by every app; dependencies point DOWN only
  core/          pure C, no IDF drivers, builds on the linux target (siot_safr, siot_evbus, siot_version, siot_util)
  platform/      the only layer that includes driver/*.h, nvs.h, esp_wifi.h (siot_board_def, siot_hal_*, siot_identity, siot_config)
  net/           moves SAFR frames (siot_link, siot_netcore, siot_coordinator, siot_provisioning)
  ui/            LED, button, console (siot_ui_led, siot_ui_button, siot_console)
  features/      Phase 2+ plug-ins; empty in Phase 1 — read features/README.md before adding one
test/
  host/          one linux-target IDF project, Unity; runs in CI on every commit (Appendix A vectors etc.)
  hil/           hardware-in-the-loop scripts for the exit checklist (3–4 boards on UART + tablet log)
ci/              build + host-test pipeline
VERSION          the only place the firmware version string is written
```

Rules (from the brief):
- Every component is prefixed `siot_` (IDF ships `console`, `log`, `nvs_flash`… — no shadowing).
- One public header per component: `include/<name>.h`; private headers under `src/`; own `Kconfig` when it has options.
- A component's `CMakeLists.txt` lists `REQUIRES` only from layers below it. Each app's `CMakeLists.txt`
  sets `EXTRA_COMPONENT_DIRS` to the five layer directories.
- Apps contain no logic: `app_main()` wires components in the boot order of the brief §3, nothing else.
- Phase 1 = `core` + `platform` + `net` + `ui`, frozen at tag `fw-0.1.0`. After that, new behaviour goes
  under `features/` only.

Build (ESP-IDF v5.5.2 only — see `/CLAUDE.md`):

```bash
source ~/.espressif/tools/activate_idf_v5.5.2.sh
cd firmware/apps/board && idf.py set-target esp32s3 && idf.py build     # once per app
cd firmware/apps/node  && idf.py set-target esp32s3 && idf.py build
cd firmware/test/host  && idf.py --preview set-target linux && idf.py build && ./build/host_tests.elf
```
