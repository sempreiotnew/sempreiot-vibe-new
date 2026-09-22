# ui/ — layer 2 (human interface)

Depends on `core` + `platform` only; never on `net`. Talks to the rest of the firmware through the
event bus (button → events, state → LED pattern).

Phase 1 components: `siot_ui_led` (from `pocs/components/siot_led`; bench LED language in
`pocs/README.md`), `siot_ui_button` (tap / double tap / ≥ 5 s hold — from `node_button.c`,
`board_button.c`), `siot_console` (nodes only, `CONFIG_SIOT_CONSOLE`; never on the board's serial port).
