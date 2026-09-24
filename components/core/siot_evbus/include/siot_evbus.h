/* siot_evbus — the firmware's event bus (brief §2, §3, §9).
 *
 * A thin wrapper over esp_event's default loop with ONE event base
 * (SIOT_EVENT) and a typed list of event ids. Every component talks to the
 * others through this bus: ui_button posts taps, netcore posts state
 * changes, ui_led listens, features (Phase 2+) subscribe without touching
 * Phase 1 files (features/README.md contract).
 *
 * Handlers run in the esp_event default-loop task and must not block.
 * Event data is copied by esp_event; handlers receive a pointer valid only
 * for the duration of the call.
 */
#pragma once

#include <stddef.h>
#include <stdint.h>

#include "esp_err.h"
#include "esp_event.h"

#ifdef __cplusplus
extern "C" {
#endif

ESP_EVENT_DECLARE_BASE(SIOT_EVENT);

/* Top-level device states (brief §3). Owned by netcore (node) /
 * coordinator (board); published with SIOT_EVT_STATE_CHANGED. */
typedef enum {
    SIOT_STATE_UNPROVISIONED_FACTORY = 0, /* no id/pop in nvs_factory */
    SIOT_STATE_SETUP,                     /* no code: setup network up */
    SIOT_STATE_JOINING,                   /* node, Mesh-Lite level 0 */
    SIOT_STATE_ONLINE,                    /* node level >= 1 / board serving */
    SIOT_STATE_DEGRADED,                  /* root without board socket, or COMM_FAULT */
    SIOT_STATE_OFFLINE,                   /* Mesh-Lite dropped to level 0 */
    SIOT_STATE_FACTORY_RESET,             /* button held >= 5 s */
} siot_state_t;

/* Event ids on SIOT_EVENT. The data struct for each id is listed after it;
 * "-" means no data. Append only: ids are part of the frozen Phase 1 API. */
typedef enum {
    SIOT_EVT_BOOT_DONE = 0,     /* -                       app_main finished wiring */
    SIOT_EVT_STATE_CHANGED,     /* siot_evt_state_t        netcore / coordinator */
    SIOT_EVT_BUTTON_TAP,        /* -                       ui_button: short tap  */
    SIOT_EVT_BUTTON_DOUBLE_TAP, /* -                       ui_button: 2nd press < 500 ms */
    SIOT_EVT_BUTTON_HOLD,       /* -                       ui_button: held >= 5 s */
    SIOT_EVT_LINK_UP,           /* siot_evt_link_t         a link backend came up */
    SIOT_EVT_LINK_DOWN,         /* siot_evt_link_t         a link backend went down */
    SIOT_EVT_MESH_LEVEL,        /* siot_evt_level_t        Mesh-Lite level changed */
    SIOT_EVT_PROVISIONED,       /* -                       /provision stored the code */
    SIOT_EVT_FACTORY_RESET,     /* -                       siot_inst erased, reboot follows */
    SIOT_EVT_IDENTIFY,          /* siot_evt_identify_t     COMMAND IDENTIFY received */
    SIOT_EVT_ALARM_SET,         /* -                       ALARM latched locally */
    SIOT_EVT_ALARM_CLEARED,     /* -                       COMMAND RESET accepted */
    SIOT_EVT_SAFR_TX,           /* siot_evt_frame_t        one frame sent (LED pulse) */
    SIOT_EVT_SAFR_RX,           /* siot_evt_frame_t        one authenticated frame received */
    SIOT_EVT_ACK_RECEIVED,      /* siot_evt_ack_t          ACK for one of our MSG_IDs */
    SIOT_EVT_ACK_TIMEOUT,       /* siot_evt_ack_t          fast phase exhausted (COMM_FAULT) */
    SIOT_EVT_TIME_SYNCED,       /* siot_evt_time_t         TIME_SYNC adopted */
    SIOT_EVT_SURVEY_RESULT,     /* siot_evt_survey_t       lifecycle §6: end of the window (count 0 = nobody) */
    SIOT_EVT_SURVEY_HEARD,      /* siot_evt_rssi_t         passive unit: a probe arrived at this RSSI */
    SIOT_EVT_SURVEY_ANSWER,     /* siot_evt_rssi_t         emitter: one unit answered, link RSSI */
    SIOT_EVT_MAX
} siot_evt_id_t;

/* Subscribing to every id on the base. */
#define SIOT_EVT_ANY ESP_EVENT_ANY_ID

typedef struct { uint8_t prev; uint8_t next; } siot_evt_state_t;       /* siot_state_t values */
typedef struct { uint8_t link_kind; } siot_evt_link_t;                 /* siot_link kind (net layer) */
typedef struct { uint8_t level; } siot_evt_level_t;                    /* 0 = not joined, 1 = root */
typedef struct { uint8_t seconds; } siot_evt_identify_t;
typedef struct { uint8_t msg_type; uint8_t src_mac[6]; } siot_evt_frame_t;
typedef struct { uint16_t msg_id; uint8_t status; } siot_evt_ack_t;    /* status: SAFR ACK STATUS */
typedef struct { uint32_t epoch; int8_t tz_offset_qh; } siot_evt_time_t;
typedef struct { uint8_t count; int8_t best_rssi; } siot_evt_survey_t; /* count 0 = nobody answered */
typedef struct { int8_t rssi; } siot_evt_rssi_t;                       /* dBm */

typedef void (*siot_evbus_handler_t)(siot_evt_id_t id, const void *data, void *ctx);

typedef struct siot_evbus_sub *siot_evbus_sub_t;

/* Creates the esp_event default loop if nobody has yet (ESP_ERR_INVALID_STATE
 * from esp_event_loop_create_default is treated as success). */
esp_err_t siot_evbus_init(void);

/* Posts `data` (copied, may be NULL with size 0). Waits at most
 * SIOT_EVBUS_POST_TIMEOUT_MS for queue space; ESP_ERR_TIMEOUT if full. */
esp_err_t siot_evbus_post(siot_evt_id_t id, const void *data, size_t size);

/* `id` is one siot_evt_id_t or SIOT_EVT_ANY. `out` receives a handle for
 * siot_evbus_unsubscribe (may be NULL if the subscription is permanent). */
esp_err_t siot_evbus_subscribe(int32_t id, siot_evbus_handler_t handler, void *ctx,
                               siot_evbus_sub_t *out);

esp_err_t siot_evbus_unsubscribe(siot_evbus_sub_t sub);

/* Name for logs, e.g. "STATE_CHANGED"; "?" for unknown ids. */
const char *siot_evt_name(siot_evt_id_t id);

#define SIOT_EVBUS_POST_TIMEOUT_MS 100

#ifdef __cplusplus
}
#endif
