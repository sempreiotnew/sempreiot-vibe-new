/* sempreiot-board — app_main: the boot sequence of brief §3, wired step by step.
 *
 * A board with no code runs setup mode; a board with a code initialises
 * SAFR, the serial link to the tablet, the installation AP + TCP server for
 * the root, and the coordinator (step 3). Nothing but wiring lives here.
 */
#include <string.h>

#include "esp_err.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "nvs_flash.h"

#include "siot_board_def.h"
#include "siot_config.h"
#include "siot_coordinator.h"
#include "siot_devtab.h"
#include "siot_evbus.h"
#include "siot_identity.h"
#include "siot_link.h"
#include "siot_provisioning.h"
#include "siot_safr.h"
#include "siot_survey.h"
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

/* /enroll during setup: the phone's work log becomes "expected" hints in the
 * device table (lifecycle §3.2), no cap of 8. */
static esp_err_t enroll_hint(const uint8_t mac[6], const char *name, const char *zone)
{
    return siot_devtab_hint(mac, name, zone);
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
    if (strcmp(siot_board_def()->family, "board") != 0) {                /* reference §2.1: wrong image for this product */
        ESP_LOGE(TAG, "model %s is a '%s' product but this is the board image: flash the %s firmware",
                 id->model, siot_board_def()->family, siot_board_def()->family);
    }
    ESP_ERROR_CHECK(siot_evbus_init());                             /* 6 (before ui: it subscribes) */
    ESP_ERROR_CHECK(siot_ui_led_init(IS_BOARD));                    /* 4-5 */
    ESP_ERROR_CHECK(siot_ui_button_init());                         /* 5: factory-reset hold armed */
    ESP_ERROR_CHECK(siot_config_init());                            /* 7 */
    ESP_ERROR_CHECK(siot_devtab_init());                            /* 7b: the device table (lifecycle §3) */

    if (!has_identity) {
        set_state(SIOT_STATE_SETUP, SIOT_STATE_UNPROVISIONED_FACTORY);
        ESP_LOGE(TAG, "no factory identity: flash nvs_factory (tools/make_sticker.py)");
        return;
    }
    if (!siot_config_has_code()) {                                  /* 10: no code → setup */
        set_state(SIOT_STATE_SETUP, SIOT_STATE_SETUP);
        siot_provisioning_set_enroll_sink(enroll_hint);
        ESP_ERROR_CHECK(siot_provisioning_start(IS_BOARD));
        ESP_ERROR_CHECK(siot_coordinator_setup_channel_start()); /* Case B over USB (lifecycle §5 B) */
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

    /* 10: board → serial link + installation AP/TCP + coordinator (root duties). */
    ESP_ERROR_CHECK(siot_link_serial_init());
    ESP_ERROR_CHECK(siot_link_mesh_board_init(code));
    ESP_ERROR_CHECK(siot_coordinator_start());
    if (siot_survey_init(0) == ESP_OK) siot_survey_set_online(true); /* answers survey probes (lifecycle §6) */
    ESP_LOGI(TAG, "normal mode: system_id=0x%04X ssid=%s name=%s",
             code->system_id, code->net_ssid, code->name);
}
