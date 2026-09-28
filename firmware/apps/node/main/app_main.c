/* sempreiot-node — app_main: the boot sequence of brief §3, wired step by step.
 *
 * A node with no code runs setup mode; a node with a code initialises
 * SAFR, Mesh-Lite (link_mesh) and netcore (step 3). Nothing but wiring
 * lives in this file.
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
#include "siot_link.h"
#include "siot_netcore.h"
#include "siot_provisioning.h"
#include "siot_safr.h"
#include "siot_survey.h"
#include "siot_ui_button.h"
#include "siot_ui_led.h"
#include "siot_version.h"
#if CONFIG_SIOT_FEATURE_LEAFMGR
#include "siot_leafmgr.h"
#endif

static const char *TAG = "node";
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

static void set_state(siot_state_t prev, siot_state_t next)
{
    const siot_evt_state_t ev = {.prev = (uint8_t)prev, .next = (uint8_t)next};
    siot_evbus_post(SIOT_EVT_STATE_CHANGED, &ev, sizeof(ev));
}

void app_main(void)
{
    ESP_LOGI(TAG, "sempreiot-node fw %s", siot_version_full());

    nvs_init();                                                     /* 1 */
    const bool has_identity = siot_identity_init() == ESP_OK;       /* 2 */
    const siot_identity_t *id = siot_identity_get();
    if (siot_board_def_select(id->model, 0) != ESP_OK) {            /* 3 */
        ESP_LOGW(TAG, "no pin map for model %s, using %s", id->model, siot_board_def()->model);
    }
    if (strcmp(siot_board_def()->family, "node") != 0) {                /* reference §2.1: wrong image for this product */
        ESP_LOGE(TAG, "model %s is a '%s' product but this is the node image: flash the %s firmware",
                 id->model, siot_board_def()->family, siot_board_def()->family);
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

    /* 10: node → Mesh-Lite link + netcore (JOINING until Mesh-Lite gives a level). */
    /* Mesh-Lite and the Wi-Fi driver narrate every scan and every failed
     * connect ("Disconnect reason : 201" = no AP found: the board is off).
     * Keep their errors, drop the play-by-play; ours stay at INFO. */
    esp_log_level_set("[vendor_ie]", ESP_LOG_ERROR);
    esp_log_level_set("[ESP_Mesh_Lite_Comm]", ESP_LOG_ERROR);
    esp_log_level_set("bridge_wifi", ESP_LOG_WARN);
    esp_log_level_set("wifi", ESP_LOG_ERROR);
    ESP_ERROR_CHECK(siot_link_mesh_node_init(code));
    ESP_ERROR_CHECK(siot_netcore_start());
    if (siot_survey_init(0xFF) != ESP_OK) ESP_LOGW(TAG, "survey mode unavailable (ESP-NOW init failed)");
#if CONFIG_SIOT_FEATURE_LEAFMGR
    if (siot_leafmgr_init() != ESP_OK) ESP_LOGW(TAG, "leaf manager unavailable"); /* parent role, protocol §12.11 */
#endif
    ESP_LOGI(TAG, "normal mode: system_id=0x%04X ssid=%s name=%s",
             code->system_id, code->net_ssid, code->name);
}
