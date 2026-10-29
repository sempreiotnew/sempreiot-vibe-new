# platform/ — layer 1

The only layer that includes ESP-IDF drivers and NVS. Wraps them in small APIs so `net/` and `ui/`
never see a GPIO number or an NVS key.

Phase 1 components: `siot_board_def` (pin map per model/hw_rev, generated from `tools/pinmap/pinmap.yaml`),
`siot_hal_gpio`, `siot_hal_pwm`, `siot_hal_serial`, `siot_identity` (read-only `nvs_factory`: id, pop,
model, STA MAC — from `pocs/components/siot_prov/prov_store.c`, factory half), `siot_config`
(NVS `siot_inst`: the code blob, name/zone, enrolled list, boot_ctr, dev_seq — installation half).
Phase 2+: `siot_devtab` (the board's device table, record versioned since protocol v3.8), `siot_labels`
(2026-10-28: the board's zone / endereçamento tables, protocol §14.1 — ids behind the names the tablet shows).
