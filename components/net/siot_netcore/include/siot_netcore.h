/* siot_netcore — what an AC node does on the network (brief §5.3, §9):
 *
 *   emitter    HEARTBEAT 15 s, TOPOLOGY 60 s, NAME_ANNOUNCE once after join
 *   button     tap → EVENT ALERT MANUAL_TEST (F_ACK_REQ, brief §14 item 3 default)
 *              double tap → EVENT ALARM SMOKE_ALARM, latched, LED red
 *   fast retry 3 × 2 s, same MSG_ID, fresh MSG_CTR; exhausted → DEGRADED +
 *              TROUBLE COMM_FAULT (spec §9.1)
 *   re-announce ALARM every 60 s with F_RETX, same DEV_SEQ, until RESET (§7.2)
 *   downlink   ACK (clears the pending frame), TIME_SYNC (adopt epoch),
 *              COMMAND (LINK_CHECK, TEST, IDENTIFY, RESET, …) — every downlink
 *              frame is also pushed to this node's children once (§6.3)
 *   states     JOINING → ONLINE → DEGRADED / OFFLINE on the bus (brief §3)
 *
 * Ported from pocs/node/main/node_safr.c with the bench mode removed and
 * the counters from siot_config / siot_safr (BOOT_CTR and DEV_SEQ persist).
 */
#pragma once

#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Requires siot_identity, siot_config (with a code), siot_safr_init,
 * siot_evbus and siot_link_mesh_node_init to have run. Starts the mesh link
 * and the 250 ms scheduler task. */
esp_err_t siot_netcore_start(void);

#ifdef __cplusplus
}
#endif
