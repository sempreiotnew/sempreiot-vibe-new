/* Board admin window (lifecycle §11): a double tap on the board suspends the
 * installation AP, raises SIOT-SETUP-<id> (WPA2 = pop) for 5 minutes and
 * serves GET /code to a phone that proves the sticker. Closes 2 s after the
 * first delivery or at the timeout, then the installation AP comes back.
 * Refused while an ALARM was heard in the last 10 minutes.
 */
#include <stdio.h>
#include <string.h>

#include "esp_log.h"
#include "esp_timer.h"

#include "coord_internal.h"
#include "siot_evbus.h"
#include "siot_identity.h"
#include "siot_link.h"
#include "siot_provisioning.h"

static const char *TAG = "siot_admin";

#define ADMIN_WINDOW_MS      (5 * 60 * 1000)
#define ADMIN_CLOSE_AFTER_MS 2000
#define ALARM_HOLD_MS        (10 * 60 * 1000)
#define SETUP_CHANNEL        6

static bool s_open;
static int64_t s_last_alarm_ms = -1;
static esp_timer_handle_t s_close_timer;

static int64_t now_ms(void) { return esp_timer_get_time() / 1000; }

static void post_state(siot_state_t prev, siot_state_t next)
{
    const siot_evt_state_t ev = {.prev = (uint8_t)prev, .next = (uint8_t)next};
    siot_evbus_post(SIOT_EVT_STATE_CHANGED, &ev, sizeof(ev));
}

static void close_window(void *arg)
{
    (void)arg;
    if (!s_open) return;
    siot_provisioning_admin_stop();
    const esp_err_t err = siot_link_mesh_board_resume();
    s_open = false;
    ESP_LOGW(TAG, "admin window closed (%s)", esp_err_to_name(err));
    post_state(SIOT_STATE_SETUP, SIOT_STATE_ONLINE);
}

static void on_delivered(void)
{
    esp_timer_stop(s_close_timer);
    esp_timer_start_once(s_close_timer, (uint64_t)ADMIN_CLOSE_AFTER_MS * 1000);
}

static void open_window(void)
{
    if (s_open) return;
    if (s_last_alarm_ms >= 0 && now_ms() - s_last_alarm_ms < ALARM_HOLD_MS) {
        ESP_LOGW(TAG, "admin window refused: an ALARM was heard in the last 10 min");
        return;
    }
    const siot_identity_t *id = siot_identity_get();
    char ssid[48]; /* "SIOT-SETUP-" + id (<= 31) */
    snprintf(ssid, sizeof(ssid), "SIOT-SETUP-%s", id->id);
    esp_err_t err = siot_link_mesh_board_suspend(ssid, id->pop, SETUP_CHANNEL);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "suspend AP: %s", esp_err_to_name(err));
        siot_link_mesh_board_resume();
        return;
    }
    err = siot_provisioning_admin_start(on_delivered);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "admin http: %s", esp_err_to_name(err));
        siot_link_mesh_board_resume();
        return;
    }
    s_open = true;
    post_state(SIOT_STATE_ONLINE, SIOT_STATE_SETUP); /* white blink while open */
    esp_timer_start_once(s_close_timer, (uint64_t)ADMIN_WINDOW_MS * 1000);
    ESP_LOGW(TAG, "admin window OPEN for %d min: %s (pop on the sticker)", ADMIN_WINDOW_MS / 60000, ssid);
}

static void on_double_tap(siot_evt_id_t id, const void *data, void *ctx)
{
    (void)id; (void)data; (void)ctx;
    open_window();
}

void coord_admin_note_alarm(void)
{
    s_last_alarm_ms = now_ms();
}

esp_err_t coord_admin_init(void)
{
    const esp_timer_create_args_t targs = {.callback = close_window, .name = "admin_close"};
    esp_err_t err = esp_timer_create(&targs, &s_close_timer);
    if (err != ESP_OK) return err;
    return siot_evbus_subscribe(SIOT_EVT_BUTTON_DOUBLE_TAP, on_double_tap, NULL, NULL);
}
