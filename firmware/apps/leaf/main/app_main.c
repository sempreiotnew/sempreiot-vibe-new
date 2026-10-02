/* sempreiot-leaf — app_main: the boot sequence of brief §3 up to "role
 * dispatch", then siot_leafcore owns the wake (protocol §12). Every wake is a
 * reboot in deep-sleep mode, so this file runs once per wake. Nothing but
 * wiring lives here.
 */
#include <string.h>

#include "esp_err.h"
#include "esp_log.h"
#include "esp_sleep.h"
#include "esp_timer.h"
#include "nvs_flash.h"

#include "siot_board_def.h"
#include "siot_config.h"
#include "siot_evbus.h"
#include "siot_identity.h"
#include "siot_leafcore.h"
#include "siot_safr.h"
#include "sdkconfig.h"
#include "siot_ui_button.h"
#include "siot_ui_led.h"
#include "siot_version.h"
#if CONFIG_SIOT_FEATURE_OTA
#include "siot_ota_leaf.h"
#include "siot_sensor.h"
#endif

static const char *TAG = "leaf";
#define IS_BOARD false

/* Brief §3 step 1: erase + retry on NO_FREE_PAGES / NEW_VERSION_FOUND. */
static void nvs_init(void)
{
    esp_err_t err = nvs_flash_init();
    if (err == ESP_ERR_NVS_NO_FREE_PAGES || err == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_ERROR_CHECK(nvs_flash_erase());
        err = nvs_flash_init();
    }
    ESP_ERROR_CHECK(err);
}

static int64_t now_ms(void)
{
    return esp_timer_get_time() / 1000;
}

void app_main(void)
{
    const bool from_sleep = esp_sleep_get_wakeup_cause() != ESP_SLEEP_WAKEUP_UNDEFINED;
    if (!from_sleep) ESP_LOGI(TAG, "sempreiot-leaf fw %s", siot_version_full());

    nvs_init();                                                     /* 1 */
    const bool has_identity = siot_identity_init() == ESP_OK;       /* 2 */
    const siot_identity_t *id = siot_identity_get();
    if (siot_board_def_select(id->model, 0) != ESP_OK) {            /* 3 */
        ESP_LOGW(TAG, "no pin map for model %s, using %s", id->model, siot_board_def()->model);
    }
    if (strcmp(siot_board_def()->family, "leaf") != 0) {                /* reference §2.1: wrong image for this product */
        ESP_LOGE(TAG, "model %s is a '%s' product but this is the leaf image: flash the %s firmware",
                 id->model, siot_board_def()->family, siot_board_def()->family);
    }
    ESP_ERROR_CHECK(siot_evbus_init());                             /* 6 (before ui: it subscribes) */
    ESP_ERROR_CHECK(siot_ui_led_init(IS_BOARD));                    /* 4-5 */
    ESP_ERROR_CHECK(siot_ui_button_init());                         /* 5: factory-reset hold armed */
    ESP_ERROR_CHECK(siot_config_init());                            /* 7 */

    if (!has_identity) {
        const siot_evt_state_t ev = {.prev = SIOT_STATE_SETUP, .next = SIOT_STATE_UNPROVISIONED_FACTORY};
        siot_evbus_post(SIOT_EVT_STATE_CHANGED, &ev, sizeof(ev));
        ESP_LOGE(TAG, "no factory identity: flash nvs_factory (tools/make_sticker.py)");
        return;
    }
    const bool has_code = siot_config_has_code();
    if (has_code) {                                                 /* 8 */
        const siot_installation_t *code = siot_config_code();
        siot_safr_config_t safr = {
            .system_id = code->system_id,
            .boot_ctr = siot_config_boot_ctr(),
            .now_ms = now_ms,
        };
        memcpy(safr.safr_psk, code->safr_psk, sizeof(safr.safr_psk));
        memcpy(safr.src_mac, id->mac, sizeof(safr.src_mac));
        ESP_ERROR_CHECK(siot_safr_init(&safr));
#if CONFIG_SIOT_FEATURE_OTA
        /* Firmware update (protocol §13.5): the feature above the runtime, wired here. */
        const siot_ota_leaf_ops_t ota_ops = {
            .send_acked = siot_leafcore_send_acked,
            .send = siot_leafcore_send,
            .battery_pct = siot_sensor_battery_pct,
            .net_ssid = code->net_ssid,
            .net_psk = code->net_psk,
        };
        if (siot_ota_leaf_init(&ota_ops) == ESP_OK) {
            const siot_leafcore_ota_t hooks = {
                .selftest_pending = siot_ota_leaf_selftest_pending,
                .selftest_verdict = siot_ota_leaf_selftest_verdict,
                .report_due = siot_ota_leaf_report_due,
                .report_if_due = siot_ota_leaf_report_if_due,
                .on_offer = siot_ota_leaf_on_offer,
            };
            siot_leafcore_set_ota(&hooks);
        } else {
            ESP_LOGE(TAG, "firmware update unavailable");
        }
#endif
    }
    siot_leafcore_run(has_code);                                    /* 10: never returns */
}
