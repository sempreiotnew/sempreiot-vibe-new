/* siot_leafmgr — parent role for battery leafs (protocol §12.11), a Phase 2
 * feature on the node image.
 *
 * Call after siot_netcore_start() and siot_survey_init(): it registers the
 * survey's raw ESP-NOW sink, netcore's TX and downlink hooks, and runs its
 * own task for custody retries, mailbox expiry and the leaf table.
 */
#pragma once

#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

esp_err_t siot_leafmgr_init(void);

#ifdef __cplusplus
}
#endif
