/* siot_ota_board — shared between the push (siot_ota_board.c), the file
 * server (ota_server.c) and the rollout (ota_rollout.c). */
#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "esp_err.h"

#include "siot_ota_proto.h"
#include "siot_safr.h"

#define OTA_FW_MOUNT   "/fw"
#define OTA_HTTP_PORT  8070 /* protocol §13.4 */

/* "/fw/<family>.<ext>" — 8.3 names, no long-file-name support needed. `out` holds 24. */
void ota_path_for(uint8_t family, const char *ext, char out[24]);
const char *ota_family_name(uint8_t family);
bool ota_store_ok(void);

/* ---- file server (ota_server.c) ---- */
esp_err_t ota_server_start(void);
void      ota_server_stop(void);

/* ---- rollout (ota_rollout.c) ---- */
esp_err_t ota_rollout_init(void);
/* COMMAND 0x1C / 0x1D from the tablet (serial rx task). */
void ota_rollout_on_control(const siot_safr_frame_t *f);
void ota_rollout_on_get(const siot_safr_frame_t *f);
/* Every 500 ms, from the OTA task. */
void ota_rollout_tick(int64_t now_ms);
/* A push of `family` was stored: whatever the last rollout of it said is history. */
void ota_rollout_on_stored(uint8_t family);
/* A rollout of `family` is rolling or paused: its image must not be replaced. */
bool ota_rollout_busy(uint8_t family);
