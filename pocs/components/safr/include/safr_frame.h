/* SAFR v3 frame codec -- build (encrypt) and parse (decrypt) whole frames.
 * Layout: docs/safr/protocol-safr-v3.md
 *
 * Ported from mocked-device/main/safr_frame.[ch] (pocs/POC-BRIEF.md 1.4/3):
 * safr_build_frame/safr_parse_frame/safr_crc16 are unchanged. The one
 * deviation is safr_frame_init() -- the mock hardcodes SYSTEM_ID and the PSK
 * as compile-time constants, but real units get both per-installation from
 * provisioning (blueprint 2, NVS "siot_inst": system_id, safr_psk), so
 * they are runtime parameters here instead.
 */
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

/* Must be called once before any build/parse call. `psk` is the
 * per-installation SAFR_PSK (16 bytes, NVS "siot_inst" safr_psk); `system_id`
 * is the per-installation SYSTEM_ID used both to stamp outgoing frames and
 * to reject frames from another installation (spec 3.1). */
void safr_frame_init(uint16_t system_id, const uint8_t psk[16]);

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
                        uint8_t flags,          /* SAFR_F_* -- F_ENC forced on */
                        uint16_t boot_ctr,
                        uint32_t msg_ctr,
                        const uint8_t *payload,
                        size_t payload_len);

/* Validates SOF/LEN/CRC, checks SYSTEM_ID, decrypts and fills `rx`.
 * Returns true on success. */
bool safr_parse_frame(const uint8_t *buf, size_t len, safr_rx_frame_t *rx);
