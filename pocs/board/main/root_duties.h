/*
 * Board's root duties (POC-BRIEF.md §4.2), ported from
 * mocked-device/main/mesh_sim.c's root-behavior functions
 * (root_send_ack/root_send_journal/emit_heartbeat/emit_topology): ACK
 * tablet downlink, forward frames both ways, RAM-ring journal + backfill,
 * HEARTBEAT/TOPOLOGY compatibility shim, and the new v3.1
 * GET_INSTALLATION -> INSTALLATION exchange.
 */
#pragma once

#include <stdint.h>

#include "board_state.h"
#include "safr_frame.h"

#ifdef __cplusplus
extern "C" {
#endif

void root_duties_init(board_state_t *st, const uint8_t board_mac[6],
                      const siot_installation_t *inst);

/* tcp_link's callback target: a frame arrived from the mesh root. */
void root_duties_handle_uplink(board_state_t *st, const uint8_t *raw,
                               size_t raw_len, const safr_rx_frame_t *rx);

/* Called by board_main after reframing a byte stream from the tablet. */
void root_duties_handle_downlink(board_state_t *st, const uint8_t *raw,
                                 size_t raw_len, const safr_rx_frame_t *rx);

/* Call every ~250ms: fires the 15s HEARTBEAT / 60s TOPOLOGY shim. */
void root_duties_step(board_state_t *st, int64_t now_ms);

#ifdef __cplusplus
}
#endif
