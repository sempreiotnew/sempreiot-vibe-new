# net/ — layer 2 (frames)

Everything that moves a SAFR frame from one place to another, node side and board side.

Phase 1 components: `siot_link` (`link_iface.h` + backends `link_mesh` [Mesh-Lite + root TCP to
192.168.4.1:5340] and `link_serial` [tablet, 115200 8N1]; Phase 2 adds `link_espnow` beside them —
from `pocs/node/main/node_mesh.c`, `pocs/board/main/tcp_link.c`, `serial_link.c`), `siot_netcore`
(node: emitter, fast-retry, re-announce, downlink dispatch, states — from `node_safr.c`),
`siot_coordinator` (board: root duties, device table, journal, INSTALLATION — from `root_duties.c`,
`board_state.h`, `installation_msg.c`), `siot_provisioning` (setup SoftAP + HTTP contract + envelope
crypto — from `pocs/components/siot_prov`).
