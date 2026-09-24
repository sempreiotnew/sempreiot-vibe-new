/* SAFR v3 frame codec — build (encrypt) and parse (decrypt) whole frames.
 * Layout: docs/safr/protocol-safr-v3.md */
#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "safr_proto.h"

typedef struct {
    uint8_t  msg_type;
    uint16_t msg_id;
    uint16_t system_id;
    uint8_t  src_mac[6];
    uint8_t  dst_mac[6];
    uint8_t  ttl;
    uint8_t  hops;
    uint8_t  flags;
    uint16_t boot_ctr;
    uint32_t msg_ctr;
    uint8_t  payload[SAFR_MAX_PAYLOAD];
    size_t   payload_len;
} safr_rx_frame_t;

void safr_frame_init(void);

uint16_t safr_crc16(const uint8_t *data, size_t len);

/* Builds a complete encrypted frame into `out` (>= SAFR_MAX_FRAME bytes).
 * Returns the frame length, or 0 on error. */
size_t safr_build_frame(uint8_t *out,
                        uint8_t msg_type,
                        uint16_t msg_id,
                        const uint8_t src_mac[6],
                        const uint8_t dst_mac[6],
                        uint8_t ttl,
                        uint8_t hops,
                        uint8_t flags,          /* SAFR_F_* — F_ENC forced on */
                        uint16_t boot_ctr,
                        uint32_t msg_ctr,
                        const uint8_t *payload,
                        size_t payload_len);

/* Validates SOF/LEN/CRC, decrypts and fills `rx`. Returns true on success. */
bool safr_parse_frame(const uint8_t *buf, size_t len, safr_rx_frame_t *rx);
