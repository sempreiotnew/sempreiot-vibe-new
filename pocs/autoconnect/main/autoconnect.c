/*
 * autoconnect — setup-network provisioning POC (siot_prov, blueprint §2-§3,
 * POC-BRIEF.md §4.1/§5).
 *
 * Scope: prove the sticker -> SoftAP -> HTTP provisioning cycle on real
 * hardware. Board/node normal-mode behaviour (raising the installation AP,
 * Mesh-Lite join) belongs to pocs/board and pocs/node and is out of scope
 * here — see README.md.
 */
#include "esp_log.h"
#include "esp_system.h"
#include "nvs_flash.h"
#include "sdkconfig.h"

#include "prov_http.h"
#include "prov_store.h"
#include "prov_types.h"
#include "wifi_softap.h"

static const char *TAG = "autoconnect";

static void on_provisioned(const siot_installation_t *inst)
{
    ESP_LOGI(TAG, "installation stored: system_id=%u net_ssid=%s channel=%u "
                  "mesh_id=%u name=%s zone=%s — normal-mode join is out of "
                  "scope for this POC, rebooting",
             inst->system_id, inst->net_ssid, inst->channel, inst->mesh_id,
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

    siot_factory_id_t factory;
    ESP_ERROR_CHECK(siot_store_load_factory(&factory));

#if CONFIG_SIOT_ROLE_BOARD
    const siot_role_t role = SIOT_ROLE_BOARD;
#else
    const siot_role_t role = SIOT_ROLE_NODE;
#endif

    siot_installation_t existing;
    if (siot_store_load_installation(&existing)) {
        ESP_LOGI(TAG, "already provisioned (system_id=%u) — normal-mode join "
                      "is out of scope for this POC; erase siot_inst to "
                      "re-enter setup mode", existing.system_id);
        return;
    }

    ESP_LOGI(TAG, "setup mode: id=%s role=%s", factory.id,
             role == SIOT_ROLE_BOARD ? "board" : "node");
    siot_wifi_softap_start(factory.id, factory.pop);
    siot_http_start(&factory, role, on_provisioned);
}
