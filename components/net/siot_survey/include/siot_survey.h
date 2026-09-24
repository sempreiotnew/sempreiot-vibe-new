/* siot_survey — the range test without the board (lifecycle §6) and the
 * leaf parent-discovery exchange (blueprint §9.2), both on ESP-NOW:
 *
 *   PARENT_PROBE  broadcast, 1 byte purpose (0 parent, 1 survey)
 *   PARENT_OFFER  unicast back, purpose ‖ rssi_seen ‖ layer
 *
 * Frames are ordinary SAFR frames (installation key, fresh MSG_CTR from
 * siot_safr_send). The owner of siot_safr's TX sink (netcore / coordinator)
 * hands probes/offers to siot_survey_tx() instead of the mesh link.
 *
 *   prober   siot_survey_probe()  → 2 s later SIOT_EVT_SURVEY_RESULT {count, best_rssi}
 *   responder every provisioned unit with Wi-Fi up: answers purpose 1 always,
 *            purpose 0 only when siot_survey_set_online(true) (AC unit ONLINE);
 *            a received probe also posts SIOT_EVT_IDENTIFY {1 s} (blue blink)
 *
 * ESP-NOW rides the SoftAP interface: on a node the AP sits on the
 * installation's fixed CHANNEL even while JOINING; on the board it is the
 * installation AP itself. Requires esp_wifi started (call after the link init).
 */
#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

/* `layer` reported in offers: 0 = the board, 0xFF = not on a mesh; nodes
 * update it with siot_survey_set_layer() as Mesh-Lite moves them. */
esp_err_t siot_survey_init(uint8_t layer);
void siot_survey_set_layer(uint8_t layer);
void siot_survey_set_online(bool online);

/* TEST press on a unit without a network: broadcast a survey probe and
 * collect offers for 2 s. ESP_ERR_INVALID_STATE while a probe is running. */
esp_err_t siot_survey_probe(void);

/* TX hook for the SAFR sink owner: true = frame was a probe/offer and went
 * out on ESP-NOW (or was dropped); false = not ours, send it as usual. */
bool siot_survey_tx(const uint8_t *frame, size_t len, const uint8_t dst_mac[6]);

#define SIOT_SURVEY_COLLECT_MS 4500 /* 4 probes 1.2 s apart (3.6 s) + the last answers */

#ifdef __cplusplus
}
#endif
