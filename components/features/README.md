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

Planned: `siot_leaf_espnow` (Phase 2), `siot_sensing`, `siot_alarm_engine`, `siot_ota_client`,
`siot_ota_server`, `siot_ota_scheduler`, `siot_siren`.
