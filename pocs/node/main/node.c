/*
 * node -- AC Mesh-Lite device, POC-BRIEF.md §4.3.
 *
 * Boot flow (blueprint §2-§3 / POC-BRIEF §4.1): if siot_inst is empty,
 * enter setup mode (siot_prov's SoftAP + HTTP server) and wait to be
 * provisioned; otherwise start normal mode (Mesh-Lite + SAFR).
 *
 * The button's >=5s factory-reset hold is armed in both modes; short/double
 * press only do something once node_safr is running (normal mode).
 */
#include "esp_log.h"
#include "esp_system.h"
#include "nvs_flash.h"

#include "prov_http.h"
#include "prov_store.h"
#include "prov_types.h"
#include "wifi_softap.h"
#include "siot_led.h"

#include "safr_frame.h"

#include "node_button.h"
#include "node_mesh.h"
#include "node_safr.h"

static const char *TAG = "node";

static void on_provisioned(const siot_installation_t *inst)
{
    ESP_LOGI(TAG, "installation stored: system_id=%u net_ssid=%s mesh_id=%u "
                  "channel=%u name=%s zone=%s -- rebooting into normal mode",
             inst->system_id, inst->net_ssid, inst->mesh_id, inst->channel,
             inst->name, inst->zone);
    esp_restart();
}

void app_main(void)
{
    esp_err_t err = nvs_flash_init();
    if (err == ESP_ERR_NVS_NO_FREE_PAGES || err == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_ERROR_CHECK(nvs_flash_erase());
        err = nvs_flash_init();
    }
    ESP_ERROR_CHECK(err);

    siot_led_init();

    siot_factory_id_t factory;
    ESP_ERROR_CHECK(siot_store_load_factory(&factory));

    siot_installation_t inst;
    if (!siot_store_load_installation(&inst)) {
        ESP_LOGI(TAG, "setup mode: id=%s", factory.id);
        siot_led_set_pattern(SIOT_LED_WHITE_BLINK, 0);
        siot_wifi_softap_start(factory.id, factory.pop);
        siot_http_start(&factory, SIOT_ROLE_NODE, on_provisioned);
        node_button_start(NULL, NULL); /* factory-reset hold only, nothing
                                         * to erase yet but harmless */
        return;
    }

    ESP_LOGI(TAG, "normal mode: system_id=%u name=%s zone=%s", inst.system_id,
             inst.name, inst.zone);
    siot_led_set_pattern(SIOT_LED_WHITE_SOLID, 0); /* finding the network;
                                            * node_safr's role LED takes over:
                                            * white solid = not joined, green
                                            * blink = ROOT, off = NODE (child) */

    safr_frame_init(inst.system_id, inst.safr_psk);
    node_mesh_start(&inst);
    node_safr_start(&inst);
    node_button_start(node_safr_on_short_press, node_safr_on_double_press);

    /* LED language from here on (see siot_led.h): white solid while not
     * joined, green blink = root, off = child node, one blue pulse per
     * frame sent or received, red solid while an ALARM is active, blue
     * blink for IDENTIFY. */
}
