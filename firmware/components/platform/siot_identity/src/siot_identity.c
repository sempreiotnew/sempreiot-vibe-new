#include "siot_identity.h"

#include <string.h>

#include "esp_log.h"
#include "esp_mac.h"
#include "nvs.h"
#include "nvs_flash.h"
#include "sdkconfig.h"

static const char *TAG = "siot_identity";

#define NVS_NS_FACT "siot_fact"

static siot_identity_t s_id;
static bool s_valid;
static bool s_model_from_factory;

static esp_err_t read_factory(void)
{
    esp_err_t err = nvs_flash_init_partition(CONFIG_SIOT_FACTORY_PARTITION);
    if (err != ESP_OK) {
        ESP_LOGW(TAG, "%s: init failed (%s)", CONFIG_SIOT_FACTORY_PARTITION, esp_err_to_name(err));
        return err == ESP_ERR_NOT_FOUND ? ESP_ERR_NOT_FOUND : err;
    }
    nvs_handle_t h;
    err = nvs_open_from_partition(CONFIG_SIOT_FACTORY_PARTITION, NVS_NS_FACT, NVS_READONLY, &h);
    if (err != ESP_OK) return ESP_ERR_NOT_FOUND; /* namespace never written */

    size_t id_len = sizeof(s_id.id);
    size_t pop_len = sizeof(s_id.pop);
    err = nvs_get_str(h, "id", s_id.id, &id_len);
    if (err == ESP_OK) err = nvs_get_str(h, "pop", s_id.pop, &pop_len);
    /* The product (model) is a factory fact too (2026-09-28, product catalogue,
     * reference §2.1): one node image serves a siren and a push-button station,
     * one leaf image every battery detector. Units stickered before this key
     * existed keep the build's CONFIG_SIOT_DEV_MODEL. */
    char model[SIOT_MODEL_MAX_LEN + 1];
    size_t model_len = sizeof(model);
    if (err == ESP_OK && nvs_get_str(h, "model", model, &model_len) == ESP_OK && model[0] != '\0') {
        strlcpy(s_id.model, model, sizeof(s_id.model));
        s_model_from_factory = true;
    }
    nvs_close(h);
    if (err != ESP_OK) return ESP_ERR_NOT_FOUND;
    if (s_id.id[0] == '\0' || strlen(s_id.pop) < SIOT_POP_MIN_LEN) return ESP_ERR_NOT_FOUND;
    return ESP_OK;
}

esp_err_t siot_identity_init(void)
{
    memset(&s_id, 0, sizeof(s_id));
    s_valid = false;

    /* Real MAC always comes from hardware, never from NVS/Kconfig. */
    esp_read_mac(s_id.mac, ESP_MAC_WIFI_STA);
    strlcpy(s_id.model, CONFIG_SIOT_DEV_MODEL, sizeof(s_id.model));

    const esp_err_t err = read_factory();
    if (err != ESP_OK) {
        memset(s_id.id, 0, sizeof(s_id.id));
        memset(s_id.pop, 0, sizeof(s_id.pop));
        ESP_LOGE(TAG, "no factory identity in %s/%s (%s): UNPROVISIONED_FACTORY",
                 CONFIG_SIOT_FACTORY_PARTITION, NVS_NS_FACT, esp_err_to_name(err));
        return err;
    }
    s_valid = true;
    ESP_LOGI(TAG, "id=%s model=%s (%s) mac=%02X:%02X:%02X:%02X:%02X:%02X", s_id.id, s_id.model,
             s_model_from_factory ? "factory" : "build default, no model on the sticker",
             s_id.mac[0], s_id.mac[1], s_id.mac[2], s_id.mac[3], s_id.mac[4], s_id.mac[5]);
    return ESP_OK;
}

const siot_identity_t *siot_identity_get(void)
{
    return &s_id;
}

bool siot_identity_valid(void)
{
    return s_valid;
}
