/* siot_ota_board — firmware push from the tablet (protocol §13.3).
 *
 *   OTA_BAUD            the link changes speed for the transfer
 *   OTA_PUSH_BEGIN      family 0x01 → this board's inactive app slot
 *                       family 0x02 / 0x03 → /fw/node.tmp / leaf.tmp in fw_store
 *   OTA_PUSH_CHUNK ...  10-byte header in the frame, the bytes raw after it
 *   OTA_PUSH_END        SHA-256, signature, project name →
 *                       OTA_PUSH_RESULT; own image: reboot into it
 *
 * A new board image must pass its self-test within CONFIG_SIOT_OTA_SELFTEST_S
 * or the board goes back to the image it ran before (OTA blueprint §4.4) and
 * tells the tablet SELFTEST_FAIL.
 */
#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

/* After siot_coordinator_start(). Mounts fw_store when the partition table
 * has one (the 8 MB board), takes the coordinator's OTA sink, starts the
 * self-test when this boot is the first of a new image. */
esp_err_t siot_ota_board_init(void);

/* What is stored for a family (SAFR_FAMILY_NODE / _LEAF): false = nothing.
 * `version` holds 25 bytes, `sha256` 32. Step 2 (the rollout) reads this. */
bool siot_ota_board_stored(uint8_t family, char *version, uint32_t *size, uint8_t *sha256);

#ifdef __cplusplus
}
#endif
