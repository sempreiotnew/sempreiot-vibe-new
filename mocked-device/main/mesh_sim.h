/* Virtual esp-mesh-lite simulation: 8 nodes (1 root, 2 relays, 5 sleeping
 * leaves) emitting SAFR v2 traffic as if relayed by the root, plus the root's
 * active behavior: ACKing central downlink and retrying critical uplink.
 * Protocol: docs/safr/protocol-safr-v3.md */
#pragma once

#include <stdint.h>

#include "safr_frame.h"

/* Provided by main: writes a frame to the serial link (UART). */
void safr_link_send(const uint8_t *frame, size_t len);

void mesh_sim_init(void);

/* Emits the deterministic spec vectors (Appendix A) — call once at boot. */
void mesh_sim_emit_boot_vectors(void);

/* Advances schedules; call every ~250 ms with esp_timer ms. */
void mesh_sim_step(int64_t now_ms);

/* Feeds a validated frame received from the central. */
void mesh_sim_handle_rx(const safr_rx_frame_t *rx, int64_t now_ms);
