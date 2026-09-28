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

#include "siot_safr.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Requires siot_identity, siot_config (with a code), siot_safr_init,
 * siot_evbus and siot_link_mesh_node_init to have run. Starts the mesh link
 * and the 250 ms scheduler task. */
esp_err_t siot_netcore_start(void);

/* ---- seams for features (protocol §12 parent role lives in features/siot_leafmgr) ----
 * A feature never includes netcore internals; it registers hooks. */

/* Called for every frame this node originates, before it goes to the mesh.
 * Return true to claim it (e.g. an ACK or a COMMAND addressed to a leaf, sent
 * over ESP-NOW instead). PARENT_PROBE / PARENT_OFFER never reach it. */
typedef bool (*siot_netcore_tx_hook_t)(const uint8_t *frame, size_t len, const uint8_t dst_mac[6], void *ctx);
void siot_netcore_set_tx_hook(siot_netcore_tx_hook_t hook, void *ctx);

/* Called for every downlink frame this node hears from the mesh (ACK,
 * COMMAND, TIME_SYNC, the board's HEARTBEAT), after netcore's own handling
 * and the one-hop relay to its mesh children; `dup` = seen before. */
typedef void (*siot_netcore_downlink_hook_t)(const siot_safr_frame_t *f, const uint8_t *raw, size_t raw_len,
                                             bool dup, void *ctx);
void siot_netcore_set_downlink_hook(siot_netcore_downlink_hook_t hook, void *ctx);

/* This node's view for a leaf's ACK (§12.4): a path to the board exists
 * (spec §9.3 rule), and the wall clock adopted from TIME_SYNC (0 = none yet). */
bool     siot_netcore_board_reachable(void);
uint32_t siot_netcore_epoch(void);

#ifdef __cplusplus
}
#endif
