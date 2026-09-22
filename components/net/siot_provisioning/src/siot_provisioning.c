#include "siot_provisioning.h"

#include "esp_log.h"
#include "esp_system.h"

#include "prov_internal.h"
#include "siot_evbus.h"
#include "siot_identity.h"

static const char *TAG = "siot_prov";

static void on_stored(void)
{
    siot_evbus_post(SIOT_EVT_PROVISIONED, NULL, 0);
    ESP_LOGI(TAG, "code stored — rebooting into normal mode");
    esp_restart();
}

esp_err_t siot_provisioning_start(bool is_board)
{
    if (!siot_identity_valid()) return ESP_ERR_INVALID_STATE;
    const siot_identity_t *id = siot_identity_get();

    esp_err_t err = prov_softap_start(id);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "softap: %s", esp_err_to_name(err));
        return err;
    }
    err = prov_http_start(id, is_board, on_stored);
    if (err != ESP_OK) ESP_LOGE(TAG, "http: %s", esp_err_to_name(err));
    return err;
}
