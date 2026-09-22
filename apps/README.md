# apps/ — one folder per firmware image

Each app is a thin ESP-IDF project: `main/app_main.c` (wires components in the boot order of the
brief §3), `sdkconfig.defaults`, `partitions_<app>.csv` (from `docs/ota/ota-and-production-blueprint-v1.md` §1),
`main/idf_component.yml` (managed deps, e.g. `espressif/mesh_lite ==1.0.2` for node), `main/Kconfig.projbuild`.

No logic here. What makes a board a board and a node a node is which components `app_main()` starts
and its Kconfig — never a separate copy of source code.

| App | Image | Flash | Runs |
|---|---|---|---|
| `board/` | sempreiot-board | 8 MB | siot_coordinator + siot_link (serial) + siot_provisioning + ui |
| `node/`  | sempreiot-node  | 4 MB | siot_netcore + siot_link (mesh) + siot_provisioning + ui |
| `leaf/`  | (Phase 2) sempreiot-leaf | 4 MB | ESP-NOW leaf — not part of Phase 1 |
