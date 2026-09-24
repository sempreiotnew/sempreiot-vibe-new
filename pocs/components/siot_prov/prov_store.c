#include "prov_store.h"

#include <string.h>

#include "esp_log.h"
#include "esp_mac.h"
#include "nvs.h"
#include "sdkconfig.h"

static const char *TAG = "siot_store";

#define NVS_NS_FACT "siot_fact"
#define NVS_NS_INST "siot_inst"

static esp_err_t load_factory_from_nvs(siot_factory_id_t *out)
{
    nvs_handle_t h;
    esp_err_t err = nvs_open(NVS_NS_FACT, NVS_READONLY, &h);
    if (err != ESP_OK) return err;

    size_t id_len = sizeof(out->id);
    size_t pop_len = sizeof(out->pop);
    err = nvs_get_str(h, "id", out->id, &id_len);
    if (err == ESP_OK) err = nvs_get_str(h, "pop", out->pop, &pop_len);
    nvs_close(h);
    return err;
}

esp_err_t siot_store_load_factory(siot_factory_id_t *out)
{
    memset(out, 0, sizeof(*out));

    /* Real MAC always comes from hardware, never from NVS/Kconfig. */
    esp_read_mac(out->mac, ESP_MAC_WIFI_STA);

    esp_err_t err = load_factory_from_nvs(out);
    if (err != ESP_OK) {
        ESP_LOGW(TAG, "siot_fact empty (%s) — using Kconfig fallback id/pop "
                      "(POC only, see README.md)", esp_err_to_name(err));
        strlcpy(out->id, CONFIG_SIOT_FACTORY_DEV_ID, sizeof(out->id));
        strlcpy(out->pop, CONFIG_SIOT_FACTORY_POP, sizeof(out->pop));
    }
    strlcpy(out->model, CONFIG_SIOT_DEV_MODEL, sizeof(out->model));
    return ESP_OK;
}

bool siot_store_load_installation(siot_installation_t *out)
{
    nvs_handle_t h;
    if (nvs_open(NVS_NS_INST, NVS_READONLY, &h) != ESP_OK) return false;

    size_t len = sizeof(*out);
    esp_err_t err = nvs_get_blob(h, "code", out, &len);
    nvs_close(h);
    return err == ESP_OK && len == sizeof(*out);
}

esp_err_t siot_store_save_installation(const siot_installation_t *inst)
{
    nvs_handle_t h;
    esp_err_t err = nvs_open(NVS_NS_INST, NVS_READWRITE, &h);
    if (err != ESP_OK) return err;

    err = nvs_set_blob(h, "code", inst, sizeof(*inst));
    if (err == ESP_OK) err = nvs_commit(h);
    nvs_close(h);
    return err;
}

esp_err_t siot_store_erase_installation(void)
{
    nvs_handle_t h;
    esp_err_t err = nvs_open(NVS_NS_INST, NVS_READWRITE, &h);
    if (err != ESP_OK) return err;
    err = nvs_erase_all(h);
    if (err == ESP_OK) err = nvs_commit(h);
    nvs_close(h);
    return err;
}

esp_err_t siot_store_save_enrolled(const siot_enrolled_entry_t *list, size_t count)
{
    if (count > SIOT_MAX_ENROLLED) count = SIOT_MAX_ENROLLED;

    nvs_handle_t h;
    esp_err_t err = nvs_open(NVS_NS_INST, NVS_READWRITE, &h);
    if (err != ESP_OK) return err;

    uint8_t count_u8 = (uint8_t)count;
    err = nvs_set_u8(h, "enrolled_n", count_u8);
    if (err == ESP_OK && count > 0) {
        err = nvs_set_blob(h, "enrolled", list, count * sizeof(*list));
    }
    if (err == ESP_OK) err = nvs_commit(h);
    nvs_close(h);
    return err;
}

size_t siot_store_load_enrolled(siot_enrolled_entry_t *out, size_t max_count)
{
    nvs_handle_t h;
    if (nvs_open(NVS_NS_INST, NVS_READONLY, &h) != ESP_OK) return 0;

    uint8_t count_u8 = 0;
    esp_err_t err = nvs_get_u8(h, "enrolled_n", &count_u8);
    if (err != ESP_OK || count_u8 == 0) {
        nvs_close(h);
        return 0;
    }

    size_t count = count_u8;
    if (count > max_count) count = max_count;

    size_t blob_len = count * sizeof(*out);
    err = nvs_get_blob(h, "enrolled", out, &blob_len);
    nvs_close(h);
    if (err != ESP_OK || blob_len != count * sizeof(*out)) return 0;
    return count;
}
