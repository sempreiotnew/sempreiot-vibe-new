#pragma once

#include <stddef.h>
#include <stdint.h>

#include "siot_config.h"

/* INSTALLATION payload (spec §7.10): SYSTEM_ID, CHANNEL, NET_SSID, NAME,
 * ENROLLED {MAC, NAME, ZONE}[m]. Never net_psk / safr_psk. `out` >= SAFR_MAX_PAYLOAD. */
size_t coord_installation_encode(const siot_installation_t *code,
                                 const siot_enrolled_entry_t *enrolled, size_t enrolled_n,
                                 uint8_t *out);
