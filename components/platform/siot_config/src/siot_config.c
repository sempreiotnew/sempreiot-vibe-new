#include "siot_config.h"

#include <string.h>

#include "esp_log.h"
#include "nvs.h"

static const char *TAG = "siot_config";

#define NVS_NS_INST "siot_inst"

static siot_installation_t s_code;
static bool     s_has_code;
static uint16_t s_boot_ctr;
static uint16_t s_dev_seq;

static esp_err_t open_ns(nvs_open_mode_t mode, nvs_handle_t *h)
{
    return nvs_open(NVS_NS_INST, mode, h);
}

static bool load_code(void)
{
    nvs_handle_t h;
    if (open_ns(NVS_READONLY, &h) != ESP_OK) return false;
    size_t len = sizeof(s_code);
    const esp_err_t err = nvs_get_blob(h, "code", &s_code, &len);
    nvs_close(h);
    if (err != ESP_OK || len != sizeof(s_code)) {
        memset(&s_code, 0, sizeof(s_code));
        return false;
    }
    return true;
}

/* boot_ctr ++ every boot, persisted before anything else runs (spec §3/§4).
 * Skips 0 and 1: 0 is "never booted", 1 is reserved for the spec's
 * deterministic vectors (brief §8). */
static esp_err_t bump_boot_ctr(void)
{
    nvs_handle_t h;
    esp_err_t err = open_ns(NVS_READWRITE, &h);
    if (err != ESP_OK) return err;

    uint16_t ctr = 0;
    err = nvs_get_u16(h, "boot_ctr", &ctr);
    if (err != ESP_OK && err != ESP_ERR_NVS_NOT_FOUND) {
        nvs_close(h);
        return err;
    }
    ctr = (uint16_t)(ctr + 1);
    if (ctr < 2) ctr = 2;
    err = nvs_set_u16(h, "boot_ctr", ctr);
    if (err == ESP_OK) err = nvs_commit(h);
    if (err == ESP_OK) {
        uint16_t seq = 0;
        if (nvs_get_u16(h, "dev_seq", &seq) == ESP_OK) s_dev_seq = seq;
    }
    nvs_close(h);
    if (err == ESP_OK) s_boot_ctr = ctr;
    return err;
}

esp_err_t siot_config_init(void)
{
    memset(&s_code, 0, sizeof(s_code));
    s_dev_seq = 0;
    const esp_err_t err = bump_boot_ctr();
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "boot_ctr: %s", esp_err_to_name(err));
        return err;
    }
    s_has_code = load_code();
    ESP_LOGI(TAG, "boot_ctr=%u dev_seq=%u code=%s", s_boot_ctr, s_dev_seq,
             s_has_code ? "present" : "none");
    return ESP_OK;
}

bool siot_config_has_code(void)
{
    return s_has_code;
}

const siot_installation_t *siot_config_code(void)
{
    return &s_code;
}

esp_err_t siot_config_save_code(const siot_installation_t *inst)
{
    if (inst == NULL) return ESP_ERR_INVALID_ARG;
    nvs_handle_t h;
    esp_err_t err = open_ns(NVS_READWRITE, &h);
    if (err != ESP_OK) return err;
    err = nvs_set_blob(h, "code", inst, sizeof(*inst));
    if (err == ESP_OK) err = nvs_commit(h);
    nvs_close(h);
    if (err == ESP_OK) {
        s_code = *inst;
        s_has_code = true;
    }
    return err;
}

esp_err_t siot_config_save_enrolled(const siot_enrolled_entry_t *list, size_t count)
{
    if (count > SIOT_MAX_ENROLLED) count = SIOT_MAX_ENROLLED;
    nvs_handle_t h;
    esp_err_t err = open_ns(NVS_READWRITE, &h);
    if (err != ESP_OK) return err;
    err = nvs_set_u8(h, "enrolled_n", (uint8_t)count);
    if (err == ESP_OK && count > 0) {
        err = nvs_set_blob(h, "enrolled", list, count * sizeof(*list));
    }
    if (err == ESP_OK) err = nvs_commit(h);
    nvs_close(h);
    return err;
}

size_t siot_config_load_enrolled(siot_enrolled_entry_t *out, size_t max_count)
{
    nvs_handle_t h;
    if (open_ns(NVS_READONLY, &h) != ESP_OK) return 0;
    uint8_t n = 0;
    esp_err_t err = nvs_get_u8(h, "enrolled_n", &n);
    if (err != ESP_OK || n == 0) {
        nvs_close(h);
        return 0;
    }
    size_t count = n;
    if (count > max_count) count = max_count;
    size_t blob_len = count * sizeof(*out);
    err = nvs_get_blob(h, "enrolled", out, &blob_len);
    nvs_close(h);
    if (err != ESP_OK || blob_len != count * sizeof(*out)) return 0;
    return count;
}

uint16_t siot_config_boot_ctr(void)
{
    return s_boot_ctr;
}

uint16_t siot_config_dev_seq(void)
{
    return s_dev_seq;
}

uint16_t siot_config_dev_seq_next(void)
{
    uint16_t next = (uint16_t)(s_dev_seq + 1);
    if (next == 0) next = 1;
    nvs_handle_t h;
    if (open_ns(NVS_READWRITE, &h) == ESP_OK) {
        if (nvs_set_u16(h, "dev_seq", next) == ESP_OK) nvs_commit(h);
        nvs_close(h);
    }
    s_dev_seq = next;
    return next;
}

esp_err_t siot_config_factory_reset(void)
{
    nvs_handle_t h;
    esp_err_t err = open_ns(NVS_READWRITE, &h);
    if (err != ESP_OK) return err;
    err = nvs_erase_all(h);
    if (err == ESP_OK) err = nvs_commit(h);
    nvs_close(h);
    if (err == ESP_OK) {
        memset(&s_code, 0, sizeof(s_code));
        s_has_code = false;
    }
    ESP_LOGW(TAG, "factory reset: %s erased (%s)", NVS_NS_INST, esp_err_to_name(err));
    return err;
}
