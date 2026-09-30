# features/ — Phase 2+ plug-ins (empty in Phase 1)

This directory is the freeze boundary. Phase 1 (`core`, `platform`, `net`, `ui`) is frozen at tag
`fw-0.1.0`; every later capability is a component here and must obey this contract:

1. **One feature = one component** `siot_<feature>/` with the standard layout (one public header,
   `src/`, `CMakeLists.txt`, `Kconfig`).
2. **Own Kconfig switch** `CONFIG_SIOT_FEATURE_<NAME>` (default n). `app_main()` calls
   `siot_<feature>_init()` inside `#if CONFIG_SIOT_FEATURE_<NAME>` and nothing else changes in the app.
3. **Talks to the system only through public APIs:** registers SAFR handlers with
   `siot_safr_register()` for **new** `MSG_TYPE`s / `CMD`s (existing payload layouts are never edited;
   fields may be appended at the end with `VER` unchanged), subscribes to `siot_evbus` events, calls
   `siot_link` / `siot_config` / `siot_hal_*` through their headers.
4. **May depend on any lower layer; nothing may depend on it.** No Phase 1 component includes a
   feature header.
5. **New pins** go into `tools/pinmap/pinmap.yaml` → `siot_board_def`; `siot_hal_*` gain functions, never
   change signatures.
6. **Spec first:** a feature that adds a wire message edits `docs/safr/protocol-safr-v3.md` before the
   code; a feature that adds behaviour gets a row in `docs/sempreiot-system-reference.md` §3.
7. **Tests:** host tests in `test/host` for anything protocol-level; HIL steps in `test/hil` for anything
   that needs a board.

Built: `siot_leafmgr` (2026-09-28, the node's parent role for battery leafs — protocol §12.11; hooks:
`siot_survey_set_raw_sink`, `siot_netcore_set_tx_hook`, `siot_netcore_set_downlink_hook`).
`siot_ota_board` (2026-09-29, protocol §13: the push from the tablet, the board's self-update, `fw_store`,
the file server and the rollout; hooks: `siot_coordinator_set_ota_sink`, `_set_ota_uplink_sink`,
`siot_link_serial_expect_raw`) and `siot_ota_node` (the unit's side of §13.4; hook:
`siot_netcore_set_command_hook`). Both behind `CONFIG_SIOT_FEATURE_OTA`, **default y** — the one feature
that is on by default, because every product image must be updatable.
Planned: `siot_sensing`, `siot_alarm_engine`, `siot_ota_leaf` (§13.5), `siot_siren`.
