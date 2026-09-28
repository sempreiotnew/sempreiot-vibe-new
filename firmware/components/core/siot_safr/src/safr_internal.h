/* Private interface between the codec (safr_frame.c) and the device-side
 * state machine (siot_safr.c). Not installed. */
#pragma once

#include "siot_safr.h"

/* Installs SYSTEM_ID and the CCM key. Returns the mbedtls rc (0 = ok). */
int safr_codec_init(uint16_t system_id, const uint8_t psk[16]);
