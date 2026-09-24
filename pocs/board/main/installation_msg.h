/*
 * INSTALLATION (MSG_TYPE 0x09) payload encoder — docs/safr/protocol-safr-v3.md
 * §7.10. Board-only, v3.1 (POC-BRIEF.md §4.2). Never encodes net_psk or
 * safr_psk.
 */
#pragma once

#include <stddef.h>
#include <stdint.h>

#include "board_state.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Writes the INSTALLATION payload into `out` (caller sizes it >=
 * SAFR_MAX_PAYLOAD). Returns the payload length. */
size_t installation_msg_encode(const board_state_t *st, uint8_t *out);

#ifdef __cplusplus
}
#endif
