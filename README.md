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
ci/              check.sh — builds both apps, checks node.bin <= 1.75 MB, builds + runs test/host
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
cd firmware/apps/node  && idf.py set-target esp32s3 && idf.py build     # pulls espressif/mesh_lite 1.0.2
cd firmware/test/host  && idf.py --preview set-target linux && idf.py build && ./build/host_tests.elf
ci/check.sh                                                             # all of the above, in order
```

Variants (flash size, console) are named build directories, built by `build.sh` and flashed by
`tools/flash.sh` with the same flags:

```bash
firmware/build.sh board                       # 8 MB product table          → apps/board/build
firmware/build.sh board --flash 4mb           # 4 MB bench devkits          → apps/board/build-4mb
firmware/build.sh board --flash 4mb --bench   # 4 MB + console on UART0     → apps/board/build-4mb-bench
firmware/build.sh node                        # node is always 4 MB         → apps/node/build
firmware/build.sh host                        # linux host tests
tools/flash.sh board /dev/cu.usbserial-XXXX --flash 4mb --bench --erase   # id = chip MAC, sticker auto
```

Round-1 bench units are all 4 MB; the product board is 8 MB (OTA blueprint §1.2: `fw_store`).
Switching is only a flag: `sdkconfig.4mb` selects `partitions_board_4mb.csv`, `sdkconfig.bench`
turns the text console on (never on a unit wired to the tablet).

Notes:
- `apps/node` prints `error: ... patch does not apply` for the four lwip patches of `iot_bridge` when
  the IDF tree already carries them (the POC build applied them). Same as `pocs/node`; the build is green.
- Adding a new component directory needs `idf.py reconfigure` in an already-configured build dir.
- `test/host` on macOS: the tests link with `-force_load` (Unity `TEST_CASE` registers through
  constructors) and one clang-only diagnostic inside IDF's own mbedtls is kept as a warning.

Status (brief §15):
- Step 1 done — skeleton, `siot_version`, `siot_util`, `siot_evbus`, `siot_safr`, host tests, `ci/check.sh`.
- Step 2 done — `siot_board_def` (from `tools/pinmap/pinmap.yaml`), `siot_hal_gpio`, `siot_hal_pwm`,
  `siot_identity` (`nvs_factory`), `siot_config` (persisted `boot_ctr`/`dev_seq`), `siot_ui_led`,
  `siot_ui_button`, `siot_provisioning`; `app_main` runs the boot sequence up to "provisioned, reboot".
  `siot_hal_serial` comes with `link_serial` in step 3 (it is the tablet link's peripheral).
- Next: step 3 (data path — `siot_link`, `siot_netcore`, `siot_coordinator`).

Bench flow for step 2 (no mesh yet): `tools/flash.sh <app> <port> --erase` (identity = chip MAC, sticker
files created in `tools/stickers/<MAC>/` on first use)
→ unit white-blinks (`SIOT-SETUP-<id>`) → provision from the installer app → unit reboots with the code
stored (board: magenta, node: white solid) → hold the button 5 s → back to white blink.
