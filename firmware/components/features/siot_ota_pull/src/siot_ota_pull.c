#include "siot_ota_pull.h"

#include <string.h>

#include "esp_app_desc.h"
#include "esp_app_format.h"
#include "esp_http_client.h"
#include "esp_log.h"
#include "esp_ota_ops.h"
#include "esp_partition.h"
#include "esp_system.h"
#include "mbedtls/sha256.h"
#include "nvs.h"

#include "siot_version.h"

static const char *TAG = "siot_ota";

#define BLOCK             4096
#define HTTP_TIMEOUT_MS   10000
#define APP_DESC_OFFSET   (sizeof(esp_image_header_t) + sizeof(esp_image_segment_header_t))
#define NVS_NS            "siot_ota"
/* What the last pull installed, written before the boot into it and erased once
 * the board was told how it ended. After a boot, if the running image is NOT
 * this one, the new image never made it and the old one says so (§13.4). */
#define NVS_KEY_PEND_VER   "pend_ver"
#define NVS_KEY_PEND_SLOT  "pend_slot"
#define NVS_KEY_PEND_AWAKE "pend_awake"

/* ---- the pending record --------------------------------------------------------- */

static void pending_write(const char *version, uint8_t slot)
{
    nvs_handle_t h;
    if (nvs_open(NVS_NS, NVS_READWRITE, &h) != ESP_OK) return;
    if (nvs_set_str(h, NVS_KEY_PEND_VER, version) == ESP_OK && nvs_set_u8(h, NVS_KEY_PEND_SLOT, slot) == ESP_OK) {
        nvs_set_u16(h, NVS_KEY_PEND_AWAKE, 0);
        nvs_commit(h);
    }
    nvs_close(h);
}

static bool pending_read(char version[SIOT_OTA_VER_MAX_LEN + 1], uint8_t *slot, uint16_t *awake_s)
{
    nvs_handle_t h;
    if (nvs_open(NVS_NS, NVS_READONLY, &h) != ESP_OK) return false;
    size_t len = SIOT_OTA_VER_MAX_LEN + 1;
    const bool ok = nvs_get_str(h, NVS_KEY_PEND_VER, version, &len) == ESP_OK &&
                    nvs_get_u8(h, NVS_KEY_PEND_SLOT, slot) == ESP_OK;
    if (ok && nvs_get_u16(h, NVS_KEY_PEND_AWAKE, awake_s) != ESP_OK) *awake_s = 0;
    nvs_close(h);
    return ok;
}

void siot_ota_pull_pending_set_awake(uint16_t awake_s)
{
    nvs_handle_t h;
    if (nvs_open(NVS_NS, NVS_READWRITE, &h) != ESP_OK) return;
    if (nvs_set_u16(h, NVS_KEY_PEND_AWAKE, awake_s) == ESP_OK) nvs_commit(h);
    nvs_close(h);
}

void siot_ota_pull_pending_clear(void)
{
    nvs_handle_t h;
    if (nvs_open(NVS_NS, NVS_READWRITE, &h) != ESP_OK) return;
    nvs_erase_key(h, NVS_KEY_PEND_VER);
    nvs_erase_key(h, NVS_KEY_PEND_SLOT);
    nvs_erase_key(h, NVS_KEY_PEND_AWAKE);
    nvs_commit(h);
    nvs_close(h);
}

void siot_ota_pull_boot_state(siot_ota_boot_t *out)
{
    memset(out, 0, sizeof(*out));
    const esp_partition_t *running = esp_ota_get_running_partition();
    esp_ota_img_states_t st = ESP_OTA_IMG_UNDEFINED;
    const bool pending_verify = running && esp_ota_get_state_partition(running, &st) == ESP_OK &&
                                st == ESP_OTA_IMG_PENDING_VERIFY;

    uint8_t slot = 0;
    if (running == NULL || !pending_read(out->version, &slot, &out->awake_s)) {
        out->version[0] = '\0';
        out->kind = pending_verify ? SIOT_OTA_BOOT_SELFTEST : SIOT_OTA_BOOT_PLAIN;
        if (pending_verify) strlcpy(out->version, siot_version_string(), sizeof(out->version));
        return;
    }
    if (running->subtype == slot) {
        /* This IS the image the record names. Unverified: its self-test. Settled
         * (valid): the OK before this boot was never acknowledged — say it again,
         * without a second self-test (a quiet board must not roll a valid image back). */
        out->kind = pending_verify ? SIOT_OTA_BOOT_SELFTEST : SIOT_OTA_BOOT_REPORT_OK;
        return;
    }
    /* The old image runs: the new one, in `slot`, was thrown away. Its otadata
     * state says how — INVALID: it gave up its own self-test; ABORTED: it started
     * but was reset (crash, watchdog, power, or a sleep without a verdict) before
     * finishing; anything else: the bootloader never ran it at all. */
    const esp_partition_t *bad = esp_partition_find_first(ESP_PARTITION_TYPE_APP, slot, NULL);
    esp_ota_img_states_t bad_st = ESP_OTA_IMG_UNDEFINED;
    if (bad != NULL) esp_ota_get_state_partition(bad, &bad_st);
    out->kind = SIOT_OTA_BOOT_ROLLED_BACK;
    out->reason = bad_st == ESP_OTA_IMG_INVALID ? SIOT_OTA_R_SELFTEST_FAIL
                : bad_st == ESP_OTA_IMG_ABORTED ? SIOT_OTA_R_NOT_VALIDATED
                                                : SIOT_OTA_R_NOT_BOOTED;
    /* ABORTED: the RTC keeps why the chip was reset across the boot into this image. */
    out->detail = bad_st == ESP_OTA_IMG_ABORTED ? (uint8_t)esp_reset_reason() : 0;
    ESP_LOGE(TAG, "%s was installed in %s and is not what runs: state %d → reason %u, reset reason %u",
             out->version, bad ? bad->label : "?", (int)bad_st, out->reason, out->detail);
}

/* ---- the pull ---------------------------------------------------------------------- */

static siot_ota_reason_t check_description(const uint8_t *first, size_t len, const char *project,
                                           const char *version)
{
    if (len < APP_DESC_OFFSET + sizeof(esp_app_desc_t)) return SIOT_OTA_R_HTTP_ERR;
    esp_app_desc_t d;
    memcpy(&d, first + APP_DESC_OFFSET, sizeof(d));
    if (first[0] != ESP_IMAGE_HEADER_MAGIC || d.magic_word != ESP_APP_DESC_MAGIC_WORD) return SIOT_OTA_R_WRONG_FAMILY;
    d.project_name[sizeof(d.project_name) - 1] = '\0';
    d.version[sizeof(d.version) - 1] = '\0';
    if (strcmp(d.project_name, project) != 0) {
        ESP_LOGE(TAG, "the image is '%s', this unit runs '%s'", d.project_name, project);
        return SIOT_OTA_R_WRONG_FAMILY;
    }
    if (strcmp(d.version, version) != 0) {
        ESP_LOGE(TAG, "the image is version '%s', the offer said '%s'", d.version, version);
        return SIOT_OTA_R_BAD_VERSION;
    }
    return SIOT_OTA_R_NONE;
}

siot_ota_reason_t siot_ota_pull_install(const siot_ota_image_t *img, const char *url, const char *project,
                                        siot_ota_pull_progress_t progress, siot_ota_pull_abort_t abort, void *ctx)
{
    const esp_partition_t *part = esp_ota_get_next_update_partition(NULL);
    if (part == NULL || img->size > part->size) return SIOT_OTA_R_NO_SPACE;

    uint8_t *buf = malloc(BLOCK);
    if (buf == NULL) return SIOT_OTA_R_NO_SPACE;

    const esp_http_client_config_t cfg = {
        .url = url,
        .timeout_ms = HTTP_TIMEOUT_MS,
        .buffer_size = BLOCK,
        .keep_alive_enable = true,
    };
    esp_http_client_handle_t http = esp_http_client_init(&cfg);
    if (http == NULL) { free(buf); return SIOT_OTA_R_HTTP_ERR; }

    siot_ota_reason_t why = SIOT_OTA_R_NONE;
    esp_ota_handle_t ota = 0;
    bool ota_open = false;
    mbedtls_sha256_context sha;
    mbedtls_sha256_init(&sha);
    mbedtls_sha256_starts(&sha, 0);
    uint32_t got = 0;
    uint8_t last_tenth = 0;

    esp_err_t err = esp_http_client_open(http, 0);
    if (err == ESP_OK) {
        esp_http_client_fetch_headers(http); /* chunked: the length is what arrives */
        const int code = esp_http_client_get_status_code(http);
        if (code != 200) {
            ESP_LOGE(TAG, "GET %s: HTTP %d", url, code);
            why = SIOT_OTA_R_HTTP_ERR;
        }
    } else {
        ESP_LOGE(TAG, "GET %s: %s", url, esp_err_to_name(err));
        why = SIOT_OTA_R_HTTP_ERR;
    }
    if (why == SIOT_OTA_R_NONE) {
        if (esp_ota_begin(part, OTA_WITH_SEQUENTIAL_WRITES, &ota) != ESP_OK) why = SIOT_OTA_R_NO_SPACE;
        else ota_open = true;
    }
    while (why == SIOT_OTA_R_NONE && got < img->size) {
        /* fill a whole block: the description check needs the first one complete */
        const uint32_t want = img->size - got < BLOCK ? img->size - got : BLOCK;
        uint32_t fill = 0;
        while (fill < want) {
            const int n = esp_http_client_read(http, (char *)buf + fill, (int)(want - fill));
            if (n <= 0) break;
            fill += (uint32_t)n;
        }
        if (fill != want) {
            ESP_LOGE(TAG, "download stopped at %lu of %lu B", (unsigned long)(got + fill), (unsigned long)img->size);
            why = SIOT_OTA_R_HTTP_ERR;
            break;
        }
        if (got == 0) {
            why = check_description(buf, fill, project, img->version);
            if (why != SIOT_OTA_R_NONE) break;
        }
        if (abort && abort(ctx)) { why = SIOT_OTA_R_BUSY_ALARM; break; } /* alarms win (§13.1) */
        if (esp_ota_write(ota, buf, fill) != ESP_OK) { why = SIOT_OTA_R_NO_SPACE; break; }
        mbedtls_sha256_update(&sha, buf, fill);
        got += fill;
        const uint8_t tenth = (uint8_t)((uint64_t)got * 10 / img->size);
        if (tenth != last_tenth) {
            last_tenth = tenth;
            ESP_LOGI(TAG, "downloading: %u %%", tenth * 10);
            if (progress) progress((uint8_t)(tenth * 10), ctx);
        }
    }
    esp_http_client_close(http);
    esp_http_client_cleanup(http);
    free(buf);

    if (why == SIOT_OTA_R_NONE) {
        uint8_t digest[32];
        mbedtls_sha256_finish(&sha, digest);
        if (memcmp(digest, img->sha256, sizeof(digest)) != 0) {
            ESP_LOGE(TAG, "SHA-256 of what arrived is not the one offered");
            why = SIOT_OTA_R_SHA_FAIL;
        }
    }
    mbedtls_sha256_free(&sha);
    if (why == SIOT_OTA_R_NONE) {
        /* esp_ota_end verifies the image and, with signed apps, its signature. */
        err = esp_ota_end(ota);
        ota_open = false;
        if (err != ESP_OK) {
            ESP_LOGE(TAG, "image refused: %s", esp_err_to_name(err));
            why = SIOT_OTA_R_SIG_FAIL;
        } else if (abort && abort(ctx)) {
            why = SIOT_OTA_R_BUSY_ALARM;
        } else if (esp_ota_set_boot_partition(part) != ESP_OK) {
            why = SIOT_OTA_R_SIG_FAIL;
        } else {
            pending_write(img->version, part->subtype); /* the next boot must be this one */
        }
    }
    if (ota_open) esp_ota_abort(ota);
    return why;
}
