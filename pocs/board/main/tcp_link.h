/*
 * Mesh-facing TCP link (POC-BRIEF.md §4.2): listens on 192.168.4.1:5340,
 * exactly one client expected (the current mesh root), reconnections
 * accepted (a new root after failover). Stream = raw SAFR frames, reframed
 * with SOF+LEN+CRC exactly like mocked-device/main/mocked-device.c's
 * rx_task, just over a socket instead of a UART.
 */
#pragma once

#include <stddef.h>
#include <stdint.h>

#include "safr_frame.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Called for every frame that passes safr_parse_frame (CRC + auth OK) from
 * the currently connected mesh root. `raw`/`raw_len` are the original wire
 * bytes (forward these unchanged to the tablet); `rx` is the already-parsed
 * view (inspect SRC_MAC/msg_type for children tracking / journaling). */
typedef void (*tcp_link_frame_cb_t)(const uint8_t *raw, size_t raw_len,
                                    const safr_rx_frame_t *rx);

/* Starts the listen/accept/reframe task. Call once, after Wi-Fi AP is up. */
void tcp_link_init(tcp_link_frame_cb_t on_uplink_frame);

/* Writes to the currently connected client; silently dropped if nobody is
 * connected (POC-BRIEF.md §4.2: no queuing across reconnects in round 1). */
void tcp_link_send(const uint8_t *frame, size_t len);

#ifdef __cplusplus
}
#endif
