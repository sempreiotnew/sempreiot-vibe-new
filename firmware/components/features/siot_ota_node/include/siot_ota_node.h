/* siot_ota_node — firmware update of a mains unit (protocol §13.4).
 *
 *   OTA_OFFER (COMMAND 0x1B)  refused: wrong family, not newer, in alarm, busy
 *   → GET http://192.168.4.1:8070/fw/node.bin, into the inactive app slot
 *   → size, SHA-256, project name, version, signature
 *   → restart → self-test: on the mesh and the board heard, within
 *     CONFIG_SIOT_OTA_SELFTEST_S → confirmed, OTA_RESULT ok
 *     otherwise the previous image comes back and says SELFTEST_FAIL
 *
 * OTA_STATUS tells the board (and the tablet) where it is; alarms win: an
 * alarm on this unit stops a download.
 */
#pragma once

#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

/* After siot_netcore_start(). */
esp_err_t siot_ota_node_init(void);

#ifdef __cplusplus
}
#endif
