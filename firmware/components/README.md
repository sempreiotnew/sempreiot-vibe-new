# components/ — all firmware code, shared by every app

Layers are directories; a component may include public headers of layers BELOW it only.

```
core/       ← nothing above it. Pure C. Builds for the linux target.        siot_safr siot_evbus siot_version siot_util
platform/   ← core.            The only layer touching ESP-IDF drivers/NVS.  siot_board_def siot_hal_gpio siot_hal_pwm siot_hal_serial siot_identity siot_config
net/        ← core, platform.  Moves SAFR frames.                           siot_link siot_netcore siot_coordinator siot_provisioning
ui/         ← core, platform.  Human interface.                             siot_ui_led siot_ui_button siot_console
features/   ← everything.      Phase 2+ plug-ins (see features/README.md).  (empty in Phase 1)
```

Every component: `siot_<name>/CMakeLists.txt`, `include/siot_<name>.h` (the ONLY public header),
`src/*.c`, optional `Kconfig`. `REQUIRES` in CMake lists lower-layer components only. Source of each
Phase 1 component (what it is ported from) is in the brief §2.
