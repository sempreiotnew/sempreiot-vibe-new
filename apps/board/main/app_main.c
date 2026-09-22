/* sempreiot-board — app_main: the boot sequence of brief §3, wired step by step.
 *
 * Step 2 of brief §15 stops at "provisioned, reboot": a board with no code
 * runs setup mode; a board with a code initialises SAFR and waits for the
 * coordinator (step 3). Nothing but wiring lives in this file.
 */
#include <string.h>

#include "esp_err.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "nvs_flash.h"

#include "siot_board_def.h"
#include "siot_config.h"
#include "siot_evbus.h"
#include "siot_identity.h"
#include "siot_provisioning.h"
#include "siot_safr.h"
#include "siot_ui_button.h"
#include "siot_ui_led.h"
#include "siot_version.h"

static const char *TAG = "board";
#define IS_BOARD true

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

static void set_state(siot_state_t prev, siot_state_t next)
{
    const siot_evt_state_t ev = {.prev = (uint8_t)prev, .next = (uint8_t)next};
    siot_evbus_post(SIOT_EVT_STATE_CHANGED, &ev, sizeof(ev));
}

void app_main(void)
{
    ESP_LOGI(TAG, "sempreiot-board fw %s", siot_version_full());

    nvs_init();                                                     /* 1 */
    const bool has_identity = siot_identity_init() == ESP_OK;       /* 2 */
    const siot_identity_t *id = siot_identity_get();
    if (siot_board_def_select(id->model, 0) != ESP_OK) {            /* 3 */
        ESP_LOGW(TAG, "no pin map for model %s, using %s", id->model, siot_board_def()->model);
    }
    ESP_ERROR_CHECK(siot_evbus_init());                             /* 6 (before ui: it subscribes) */
    ESP_ERROR_CHECK(siot_ui_led_init(IS_BOARD));                    /* 4-5 */
    ESP_ERROR_CHECK(siot_ui_button_init());                         /* 5: factory-reset hold armed */
    ESP_ERROR_CHECK(siot_config_init());                            /* 7 */

    if (!has_identity) {
        set_state(SIOT_STATE_SETUP, SIOT_STATE_UNPROVISIONED_FACTORY);
        ESP_LOGE(TAG, "no factory identity: flash nvs_factory (tools/make_sticker.py)");
        return;
    }
    if (!siot_config_has_code()) {                                  /* 10: no code → setup */
        set_state(SIOT_STATE_SETUP, SIOT_STATE_SETUP);
        ESP_ERROR_CHECK(siot_provisioning_start(IS_BOARD));
        return;
    }

    const siot_installation_t *code = siot_config_code();           /* 8 */
    siot_safr_config_t safr = {
        .system_id = code->system_id,
        .boot_ctr = siot_config_boot_ctr(),
        .now_ms = now_ms,
    };
    memcpy(safr.safr_psk, code->safr_psk, sizeof(safr.safr_psk));
    memcpy(safr.src_mac, id->mac, sizeof(safr.src_mac));
    ESP_ERROR_CHECK(siot_safr_init(&safr));
    siot_safr_set_level(0);

    /* 10: board → coordinator_start() arrives with step 3. Until then the
     * board reports itself ONLINE (magenta) so the bench shows it booted. */
    set_state(SIOT_STATE_SETUP, SIOT_STATE_ONLINE);
    ESP_LOGI(TAG, "normal mode: system_id=0x%04X ssid=%s name=%s (coordinator: step 3)",
             code->system_id, code->net_ssid, code->name);
}
