/* siot_coordinator — the board as control unit (brief §8), Phase 1 step 3:
 *
 *   uplink   (root → board, SIOT_LINK_MESH): every valid frame is forwarded
 *            to the tablet byte-for-byte; the board only observes SRC_MAC /
 *            MSG_TYPE to track children and journal EVENTs (once per frame,
 *            fast retries are forwarded but not journaled twice)
 *   downlink (tablet → board, SIOT_LINK_SERIAL):
 *            COMMAND / TIME_SYNC  ACKed by the board (SRC_MAC = board) AND
 *                                 forwarded into the mesh unchanged
 *            GET_INSTALLATION     answered with INSTALLATION, never forwarded
 *            EVENT_LOG_REQ        answered from the journal, never forwarded
 *            ACK                  forwarded into the mesh (brief §14 item 4:
 *                                 the POC dropped them, so a node never saw
 *                                 the tablet's ACK)
 *            anything else        dropped
 *   shim     own HEARTBEAT every 15 s and TOPOLOGY every 60 s with LAYER 0,
 *            role root, PARENT_MAC = central, children = AC devices heard
 *   button   tap → broadcast COMMAND TEST into the mesh so every node raises
 *            its own MANUAL_TEST (site-wide walk test); the board raises no
 *            event of its own
 *
 * Step 4 adds the device_table with "missing" after 45 s, the flash
 * journal, the TIME_SYNC wall clock and the ALARM-first queue.
 * Ported from pocs/board/main/root_duties.c + installation_msg.c.
 */
#pragma once

#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Requires siot_identity, siot_config (with a code), siot_safr_init,
 * siot_evbus, siot_link_serial_init and siot_link_mesh_board_init. Starts
 * both links and the 250 ms tick task. */
esp_err_t siot_coordinator_start(void);

/* Board in SETUP (no code): listen on USB for the tablet's SET_INSTALLATION
 * on the setup channel (spec §3.1, Case B). Requires siot_identity. The
 * board reboots into normal mode once the code is stored. */
esp_err_t siot_coordinator_setup_channel_start(void);

/* ---- firmware update (protocol §13): the coordinator owns the links and the
 * dispatcher, siot_ota_board owns what the frames mean ----------------------- */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "siot_safr.h"

/* OTA_PUSH_BEGIN / CHUNK / END and the OTA_* COMMANDs (0x1A–0x1D), and only
 * when they arrived on the SERIAL link: a frame of these kinds coming from
 * the mesh is dropped, a unit never pushes firmware to the board. Runs in the
 * serial link's rx task. */
typedef void (*siot_coordinator_ota_cb_t)(const siot_safr_frame_t *f, bool dup, void *ctx);
void siot_coordinator_set_ota_sink(siot_coordinator_ota_cb_t cb, void *ctx);

/* A frame the board originates for the tablet, and the ACK of one of the
 * tablet's frames (DETAIL = a §13.7 REASON for the OTA messages). */
void siot_coordinator_send_to_tablet(uint8_t msg_type, uint8_t flags, const uint8_t *payload, size_t len);
void siot_coordinator_ack_tablet(uint16_t acked_msg_id, uint8_t status, uint8_t detail);

/* An ALARM crossed the board in the last 10 minutes (the rule of the admin
 * window, lifecycle §11): no board restart now. */
bool siot_coordinator_alarm_recent(void);

/* The board's own NAME_ANNOUNCE (§7.11): what it is and the firmware it runs. */
void siot_coordinator_announce_board(void);

#ifdef __cplusplus
}
#endif
