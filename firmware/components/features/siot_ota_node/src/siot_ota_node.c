#include "siot_ota_node.h"

#include <string.h>

#include "esp_app_desc.h"
#include "esp_app_format.h"
#include "esp_http_client.h"
#include "esp_log.h"
#include "esp_ota_ops.h"
#include "esp_partition.h"
#include "esp_system.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "freertos/task.h"
#include "mbedtls/sha256.h"
#include "nvs.h"
#include "sdkconfig.h"

#include "siot_evbus.h"
#include "siot_link.h"
#include "siot_netcore.h"
#include "siot_ota_proto.h"
#include "siot_safr.h"
#include "siot_util.h"
#include "siot_version.h"

static const char *TAG = "siot_ota";

#define FAMILY            SAFR_FAMILY_NODE
#define PROJECT_NAME      "sempreiot-node"
#define IMAGE_URL         "http://192.168.4.1:8070/fw/node.bin" /* protocol §13.4 */
#define BLOCK             4096
#define HTTP_TIMEOUT_MS   10000
#define APP_DESC_OFFSET   (sizeof(esp_image_header_t) + sizeof(esp_image_segment_header_t))
#define RESULT_ACK_MS     3000   /* one try of OTA_RESULT waits this long for an ACK */
#define RESULT_TRIES      3      /* tries per call of send_result(): 9 s at most, never longer — an offer
                                    must be worked at once, so an unacknowledged report is retried from
                                    the task's idle loop (REPORT_RETRY_MS) until the board answers */
#define REPORT_RETRY_MS   20000
#define SELFTEST_SAY_MS   10000  /* OTA_STATUS selftest is repeated this often while waiting */
#define NVS_NS            "siot_ota"
#define NVS_KEY_REPORTED  "rb_reported"
/* What the last download installed, written just before the restart into it and
 * erased once the board was told how it ended. After a restart, if the running
 * image is NOT this one, the new image never made it and the old one says so. */
#define NVS_KEY_PEND_VER  "pend_ver"
#define NVS_KEY_PEND_SLOT "pend_slot"

#if CONFIG_SIOT_OTA_ALLOW_FORCE
#define FORCE_ALLOWED true
#else
#define FORCE_ALLOWED false
#endif
/* TEST ONLY (docs/ota/before-production.md item 1): the same switch as the board's. */
#if CONFIG_SIOT_OTA_TEST_ANY_VERSION
#define ANY_VERSION true
#else
#define ANY_VERSION false
#endif

static TaskHandle_t s_task;
static SemaphoreHandle_t s_lock;
static siot_ota_image_t s_offer;      /* the offer taken */
static bool s_busy;                   /* an offer is being worked on */
static bool s_selftest;               /* this boot is the first of a new image */
static bool s_rollback_pending;       /* an image was thrown away and nobody was told */
static bool s_report_ok_pending;      /* this image is in, and the board was never told */
/* The last OTA_RESULT nobody acknowledged: said again from the idle loop. */
static bool    s_report_due;
static bool    s_report_ok;
static uint8_t s_report_reason, s_report_detail;
static bool    s_report_clears_pending; /* acknowledged → the pending record (and the sha note) go */
static uint8_t s_rollback_reason;     /* ... and why (SELFTEST_FAIL / NOT_VALIDATED / NOT_BOOTED) */
static uint8_t s_rollback_detail;     /* NOT_VALIDATED: the reset reason that ended the new image */
static char s_rollback_version[SIOT_OTA_VER_MAX_LEN + 1]; /* the image that was thrown away */
static uint8_t s_rollback_id[8];      /* legacy: its ELF sha, when no pending record names it */
static volatile uint16_t s_result_msg_id;
static volatile bool s_result_acked;

static int64_t now_ms(void) { return esp_timer_get_time() / 1000; }

/* ---- the pending record (NVS) ------------------------------------------------------ */

static void pending_write(const char *version, uint8_t slot)
{
    nvs_handle_t h;
    if (nvs_open(NVS_NS, NVS_READWRITE, &h) != ESP_OK) return;
    if (nvs_set_str(h, NVS_KEY_PEND_VER, version) == ESP_OK && nvs_set_u8(h, NVS_KEY_PEND_SLOT, slot) == ESP_OK) {
        nvs_commit(h);
    }
    nvs_close(h);
}

static void pending_clear(void)
{
    nvs_handle_t h;
    if (nvs_open(NVS_NS, NVS_READWRITE, &h) != ESP_OK) return;
    nvs_erase_key(h, NVS_KEY_PEND_VER);
    nvs_erase_key(h, NVS_KEY_PEND_SLOT);
    nvs_commit(h);
    nvs_close(h);
}

static bool pending_read(char version[SIOT_OTA_VER_MAX_LEN + 1], uint8_t *slot)
{
    nvs_handle_t h;
    if (nvs_open(NVS_NS, NVS_READONLY, &h) != ESP_OK) return false;
    size_t len = SIOT_OTA_VER_MAX_LEN + 1;
    const bool ok = nvs_get_str(h, NVS_KEY_PEND_VER, version, &len) == ESP_OK &&
                    nvs_get_u8(h, NVS_KEY_PEND_SLOT, slot) == ESP_OK;
    nvs_close(h);
    return ok;
}

/* ---- frames up ---------------------------------------------------------------------- */

static void send_status(uint8_t state, uint8_t percent)
{
    const siot_ota_status_t st = {.state = state, .percent = percent};
    uint8_t p[SIOT_OTA_STATUS_LEN];
    siot_safr_set_level(siot_link_mesh_level());
    siot_safr_send(SAFR_BCAST_MAC, SAFR_MSG_OTA_STATUS, siot_safr_next_msg_id(), 0, p,
                   siot_ota_status_encode(p, &st));
}

static void on_ack(siot_evt_id_t id, const void *data, void *ctx)
{
    (void)id; (void)ctx;
    const siot_evt_ack_t *a = data;
    if (s_result_msg_id != 0 && a->msg_id == s_result_msg_id) s_result_acked = true;
}

/* OTA_RESULT, repeated under the same MSG_ID until somebody acknowledges it
 * (§13.4): RESULT_TRIES here, then from the idle loop (report_later) — this
 * task must stay free to take the next offer. Returns true when acknowledged. */
static bool board_heard(void);
static void report(bool ok, uint8_t reason, uint8_t detail, bool clears_pending);

static bool send_result(bool ok, uint8_t reason, uint8_t detail)
{
    siot_ota_result_t r = {.ok = ok, .reason = reason, .awake_s = 0, .detail = detail};
    strlcpy(r.version, siot_version_string(), sizeof(r.version));
    uint8_t p[SAFR_MAX_PAYLOAD];
    const size_t n = siot_ota_result_encode(p, &r);
    const uint16_t id = siot_safr_next_msg_id();
    s_result_acked = false;
    s_result_msg_id = id;
    int tries = 0;
    while (!s_result_acked && tries < RESULT_TRIES && board_heard()) {
        tries++;
        siot_safr_set_level(siot_link_mesh_level());
        siot_safr_send(SAFR_BCAST_MAC, SAFR_MSG_OTA_RESULT, id, SAFR_F_ACK_REQ, p, n);
        const int64_t until = now_ms() + RESULT_ACK_MS;
        while (!s_result_acked && now_ms() < until) vTaskDelay(pdMS_TO_TICKS(100));
    }
    ESP_LOGW(TAG, "OTA_RESULT %s reason %u detail %u, running %s: %s after %d tries", ok ? "OK" : "FAILED",
             reason, detail, r.version, s_result_acked ? "acknowledged" : "nobody acknowledged it", tries);
    s_result_msg_id = 0;
    return s_result_acked;
}

/* ---- the offer (link rx task) ----------------------------------------------------------- */

static uint8_t on_command(uint8_t cmd, const uint8_t *args, size_t alen, bool dup, uint8_t *detail, void *ctx)
{
    (void)ctx;
    if (cmd != SAFR_CMD_OTA_OFFER) { *detail = SIOT_OTA_R_BAD_ARGS; return SAFR_ACK_ERROR; }
    siot_ota_image_t img;
    if (!siot_ota_offer_decode(args, alen, &img)) { *detail = SIOT_OTA_R_BAD_ARGS; return SAFR_ACK_ERROR; }

    xSemaphoreTake(s_lock, portMAX_DELAY);
    uint8_t why = SIOT_OTA_R_NONE;
    const bool same = s_busy && s_offer.size == img.size &&
                      memcmp(s_offer.sha256, img.sha256, SIOT_OTA_SHA_LEN) == 0;
    if (dup || same) {
        /* the board did not get our ACK and asks again: the answer is the one we gave */
        why = same ? SIOT_OTA_R_NONE : SIOT_OTA_R_BUSY;
    } else if (img.family != FAMILY) {
        why = SIOT_OTA_R_WRONG_FAMILY;
    } else if (s_busy || s_selftest) {
        why = SIOT_OTA_R_BUSY;
    } else if (siot_netcore_alarm_active()) {
        why = SIOT_OTA_R_BUSY_ALARM;
    } else {
        why = siot_ota_accept_version(siot_version_string(), img.version,
                                      ANY_VERSION || (img.flags & SIOT_OTA_F_FORCE) != 0,
                                      ANY_VERSION || FORCE_ALLOWED);
        if (why == SIOT_OTA_R_NONE) {
            if (ANY_VERSION) {
                ESP_LOGE(TAG, "TEST BUILD: version rule OFF — taking %s over %s without comparing them",
                         img.version, siot_version_string());
            }
            s_offer = img;
            s_busy = true;
            xTaskNotifyGive(s_task);
        }
    }
    xSemaphoreGive(s_lock);
    if (why != SIOT_OTA_R_NONE) {
        ESP_LOGW(TAG, "offer of %s refused: reason %u", img.version, why);
        *detail = why;
        return SAFR_ACK_ERROR;
    }
    ESP_LOGW(TAG, "offer of %s taken (%lu B)", img.version, (unsigned long)img.size);
    return SAFR_ACK_OK;
}

/* ---- the download (its own task) ------------------------------------------------------------ */

static siot_ota_reason_t check_description(const uint8_t *first, size_t len)
{
    if (len < APP_DESC_OFFSET + sizeof(esp_app_desc_t)) return SIOT_OTA_R_HTTP_ERR;
    esp_app_desc_t d;
    memcpy(&d, first + APP_DESC_OFFSET, sizeof(d));
    if (first[0] != ESP_IMAGE_HEADER_MAGIC || d.magic_word != ESP_APP_DESC_MAGIC_WORD) return SIOT_OTA_R_WRONG_FAMILY;
    d.project_name[sizeof(d.project_name) - 1] = '\0';
    d.version[sizeof(d.version) - 1] = '\0';
    if (strcmp(d.project_name, PROJECT_NAME) != 0) {
        ESP_LOGE(TAG, "the image is '%s', this unit runs " PROJECT_NAME, d.project_name);
        return SIOT_OTA_R_WRONG_FAMILY;
    }
    if (strcmp(d.version, s_offer.version) != 0) {
        ESP_LOGE(TAG, "the image is version '%s', the offer said '%s'", d.version, s_offer.version);
        return SIOT_OTA_R_BAD_VERSION;
    }
    return SIOT_OTA_R_NONE;
}

static siot_ota_reason_t download_and_install(void)
{
    const esp_partition_t *part = esp_ota_get_next_update_partition(NULL);
    if (part == NULL || s_offer.size > part->size) return SIOT_OTA_R_NO_SPACE;

    uint8_t *buf = malloc(BLOCK);
    if (buf == NULL) return SIOT_OTA_R_NO_SPACE;

    const esp_http_client_config_t cfg = {
        .url = IMAGE_URL,
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
            ESP_LOGE(TAG, "GET " IMAGE_URL ": HTTP %d", code);
            why = SIOT_OTA_R_HTTP_ERR;
        }
    } else {
        ESP_LOGE(TAG, "GET " IMAGE_URL ": %s", esp_err_to_name(err));
        why = SIOT_OTA_R_HTTP_ERR;
    }
    if (why == SIOT_OTA_R_NONE) {
        if (esp_ota_begin(part, OTA_WITH_SEQUENTIAL_WRITES, &ota) != ESP_OK) why = SIOT_OTA_R_NO_SPACE;
        else ota_open = true;
    }
    while (why == SIOT_OTA_R_NONE && got < s_offer.size) {
        /* fill a whole block: the description check needs the first one complete */
        const uint32_t want = s_offer.size - got < BLOCK ? s_offer.size - got : BLOCK;
        uint32_t fill = 0;
        while (fill < want) {
            const int n = esp_http_client_read(http, (char *)buf + fill, (int)(want - fill));
            if (n <= 0) break;
            fill += (uint32_t)n;
        }
        if (fill != want) {
            ESP_LOGE(TAG, "download stopped at %lu of %lu B", (unsigned long)(got + fill),
                     (unsigned long)s_offer.size);
            why = SIOT_OTA_R_HTTP_ERR;
            break;
        }
        if (got == 0) {
            why = check_description(buf, fill);
            if (why != SIOT_OTA_R_NONE) break;
        }
        if (siot_netcore_alarm_active()) { why = SIOT_OTA_R_BUSY_ALARM; break; } /* alarms win (§13.1) */
        if (esp_ota_write(ota, buf, fill) != ESP_OK) { why = SIOT_OTA_R_NO_SPACE; break; }
        mbedtls_sha256_update(&sha, buf, fill);
        got += fill;
        const uint8_t tenth = (uint8_t)((uint64_t)got * 10 / s_offer.size);
        if (tenth != last_tenth) {
            last_tenth = tenth;
            ESP_LOGI(TAG, "downloading: %u %%", tenth * 10);
            send_status(SIOT_OTA_U_DOWNLOADING, (uint8_t)(tenth * 10));
        }
    }
    esp_http_client_close(http);
    esp_http_client_cleanup(http);
    free(buf);

    if (why == SIOT_OTA_R_NONE) {
        send_status(SIOT_OTA_U_VERIFYING, 100);
        uint8_t digest[32];
        mbedtls_sha256_finish(&sha, digest);
        if (memcmp(digest, s_offer.sha256, sizeof(digest)) != 0) {
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
        } else if (siot_netcore_alarm_active()) {
            why = SIOT_OTA_R_BUSY_ALARM;
        } else if (esp_ota_set_boot_partition(part) != ESP_OK) {
            why = SIOT_OTA_R_SIG_FAIL;
        } else {
            pending_write(s_offer.version, part->subtype); /* the next boot must be this one */
        }
    }
    if (ota_open) esp_ota_abort(ota);
    return why;
}

/* ---- self-test, rollback report (the same task) -------------------------------------------------- */

static bool board_heard(void)
{
    return siot_link_mesh_level() > 0 && siot_netcore_board_reachable();
}

static void run_selftest(void)
{
    const int64_t deadline = now_ms() + (int64_t)CONFIG_SIOT_OTA_SELFTEST_S * 1000;
    ESP_LOGW(TAG, "first boot of %s: self-test, %d s to be on the mesh and hear the board",
             siot_version_string(), CONFIG_SIOT_OTA_SELFTEST_S);
    /* Nothing leaves before the path to the board is proven (a downlink frame
     * heard; the root's TCP session up) — the rule every other frame of this
     * unit follows (siot_netcore.c `path_proven`). A Mesh-Lite level alone
     * means "associated to a parent", not "the link to it is ready", and this
     * task is the only one that would transmit in that gap. */
    int64_t next_say = 0;
    while (now_ms() < deadline) {
        if (board_heard() && now_ms() >= next_say) {
            send_status(SIOT_OTA_U_SELFTEST, 100); /* never acknowledged: said again while waiting */
            next_say = now_ms() + SELFTEST_SAY_MS;
        }
#if !CONFIG_SIOT_OTA_SELFTEST_FAIL
        if (board_heard()) {
            const esp_err_t err = esp_ota_mark_app_valid_cancel_rollback();
            ESP_LOGW(TAG, "self-test passed: %s is now this unit's firmware (%s)", siot_version_string(),
                     esp_err_to_name(err));
            xSemaphoreTake(s_lock, portMAX_DELAY);
            s_selftest = false;
            xSemaphoreGive(s_lock);
            report(true, SIOT_OTA_R_NONE, 0, true); /* acknowledged → the record goes: settled */
            return;
        }
#endif
        vTaskDelay(pdMS_TO_TICKS(500));
    }
    ESP_LOGE(TAG, "self-test failed: back to the previous firmware");
    vTaskDelay(pdMS_TO_TICKS(100));
    esp_ota_mark_app_invalid_rollback_and_reboot(); /* does not return when it works */
    ESP_LOGE(TAG, "rollback refused: no other image to go back to");
    xSemaphoreTake(s_lock, portMAX_DELAY);
    s_selftest = false;
    xSemaphoreGive(s_lock);
}

/* The result to tell the board, now and — if nobody acknowledges it — again
 * from the idle loop every REPORT_RETRY_MS. Once acknowledged, a report of a
 * rollback erases the pending record (and writes the legacy sha note), so a
 * lost report is made again on the next boot rather than never. */
static void report_done(void)
{
    s_report_due = false;
    if (!s_report_clears_pending) return;
    pending_clear();
    nvs_handle_t h;
    if (nvs_open(NVS_NS, NVS_READWRITE, &h) == ESP_OK) {
        if (nvs_set_blob(h, NVS_KEY_REPORTED, s_rollback_id, sizeof(s_rollback_id)) == ESP_OK) nvs_commit(h);
        nvs_close(h);
    }
}

static void report(bool ok, uint8_t reason, uint8_t detail, bool clears_pending)
{
    s_report_ok = ok;
    s_report_reason = reason;
    s_report_detail = detail;
    s_report_clears_pending = clears_pending;
    s_report_due = true;
    if (send_result(ok, reason, detail)) report_done();
}

static void report_again(void)
{
    if (!s_report_due || !board_heard()) return;
    if (send_result(s_report_ok, s_report_reason, s_report_detail)) report_done();
}

/* The old image, back after the new one was thrown away: tell the board. */
static void report_rollback(void)
{
    ESP_LOGE(TAG, "telling the board: %s did not make it (reason %u, detail %u), this is %s again",
             s_rollback_version, s_rollback_reason, s_rollback_detail, siot_version_string());
    report(false, s_rollback_reason, s_rollback_detail, true);
    s_rollback_pending = false;
}

static void boot_state(void)
{
    const esp_partition_t *running = esp_ota_get_running_partition();
    esp_ota_img_states_t st = ESP_OTA_IMG_UNDEFINED;
    if (running && esp_ota_get_state_partition(running, &st) == ESP_OK && st == ESP_OTA_IMG_PENDING_VERIFY) {
        s_selftest = true;
    }

    /* 1. The record of the last install says which image should be running now. */
    char pend_ver[SIOT_OTA_VER_MAX_LEN + 1];
    uint8_t pend_slot = 0;
    if (running && pending_read(pend_ver, &pend_slot)) {
        if (running->subtype == pend_slot) {
            if (!s_selftest) {
                /* This IS the new image and its state is already settled (valid): the
                 * OK before this boot was never acknowledged — say it again, without a
                 * second self-test (a quiet board must not roll a valid image back). */
                ESP_LOGW(TAG, "%s runs and its result was never acknowledged: reporting it again",
                         siot_version_string());
                s_report_ok_pending = true;
            }
            return;
        }
        /* The old image runs: the new one, in `pend_slot`, was thrown away. Its otadata
         * state says how — INVALID: it gave up its own self-test; ABORTED: it started but
         * was reset (crash, watchdog, power) before finishing; anything else: the
         * bootloader never ran it at all. */
        const esp_partition_t *bad = esp_partition_find_first(ESP_PARTITION_TYPE_APP, pend_slot, NULL);
        esp_ota_img_states_t bad_st = ESP_OTA_IMG_UNDEFINED;
        if (bad != NULL) esp_ota_get_state_partition(bad, &bad_st);
        s_rollback_reason = bad_st == ESP_OTA_IMG_INVALID ? SIOT_OTA_R_SELFTEST_FAIL
                          : bad_st == ESP_OTA_IMG_ABORTED ? SIOT_OTA_R_NOT_VALIDATED
                                                          : SIOT_OTA_R_NOT_BOOTED;
        /* ABORTED: the bootloader found the new image still unverified, so the chip was
         * reset while it ran. The RTC keeps why (panic, a watchdog, brownout, esp_restart)
         * across that boot; this is the first image to read it. */
        s_rollback_detail = bad_st == ESP_OTA_IMG_ABORTED ? (uint8_t)esp_reset_reason() : 0;
        strlcpy(s_rollback_version, pend_ver, sizeof(s_rollback_version));
        esp_app_desc_t d;
        if (bad != NULL && esp_ota_get_partition_description(bad, &d) == ESP_OK) {
            memcpy(s_rollback_id, d.app_elf_sha256, sizeof(s_rollback_id));
        }
        ESP_LOGE(TAG, "%s was installed in %s and is not what runs: state %d → reason %u, reset reason %u",
                 pend_ver, bad ? bad->label : "?", (int)bad_st, s_rollback_reason, s_rollback_detail);
        s_rollback_pending = true;
        return;
    }

    /* 2. No record (an image installed by an older client): an invalid slot is
     *    reported once per image, as before. */
    const esp_partition_t *bad = esp_ota_get_last_invalid_partition();
    esp_app_desc_t d;
    if (bad != NULL && esp_ota_get_partition_description(bad, &d) == ESP_OK) {
        memcpy(s_rollback_id, d.app_elf_sha256, sizeof(s_rollback_id));
        d.version[sizeof(d.version) - 1] = '\0';
        strlcpy(s_rollback_version, d.version, sizeof(s_rollback_version));
        s_rollback_reason = SIOT_OTA_R_SELFTEST_FAIL;
        uint8_t told[sizeof(s_rollback_id)] = {0};
        size_t len = sizeof(told);
        nvs_handle_t h;
        bool known = false;
        if (nvs_open(NVS_NS, NVS_READONLY, &h) == ESP_OK) {
            known = nvs_get_blob(h, NVS_KEY_REPORTED, told, &len) == ESP_OK && len == sizeof(told) &&
                    memcmp(told, s_rollback_id, sizeof(told)) == 0;
            nvs_close(h);
        }
        s_rollback_pending = !known;
    }
}

static void ota_task(void *arg)
{
    (void)arg;
    if (s_selftest) run_selftest();
    if (s_rollback_pending) report_rollback();
    if (s_report_ok_pending) report(true, SIOT_OTA_R_NONE, 0, true);
    for (;;) {
        /* An offer wakes this at once; otherwise an unacknowledged report is said again. */
        if (ulTaskNotifyTake(pdTRUE, pdMS_TO_TICKS(REPORT_RETRY_MS)) == 0) {
            report_again();
            continue;
        }
        send_status(SIOT_OTA_U_DOWNLOADING, 0);
        const siot_ota_reason_t why = download_and_install();
        if (why == SIOT_OTA_R_NONE) {
            ESP_LOGW(TAG, "%s verified: restarting into it", s_offer.version);
            send_status(SIOT_OTA_U_REBOOTING, 100);
            vTaskDelay(pdMS_TO_TICKS(1500)); /* the status must leave first */
            esp_restart();
        }
        ESP_LOGE(TAG, "update to %s failed: reason %u, still running %s", s_offer.version, why,
                 siot_version_string());
        report(false, (uint8_t)why, 0, false);
        xSemaphoreTake(s_lock, portMAX_DELAY);
        s_busy = false;
        xSemaphoreGive(s_lock);
    }
}

esp_err_t siot_ota_node_init(void)
{
    if (s_lock == NULL) s_lock = xSemaphoreCreateMutex();
    if (s_lock == NULL) return ESP_ERR_NO_MEM;
    boot_state();
    esp_err_t err = siot_evbus_subscribe(SIOT_EVT_ACK_RECEIVED, on_ack, NULL, NULL);
    if (err != ESP_OK) return err;
    /* 8 KB: the signature check (RSA-3072) and the HTTP client run here */
    if (xTaskCreatePinnedToCore(ota_task, "siot_ota", 8192, NULL, 5, &s_task, 0) != pdPASS) return ESP_ERR_NO_MEM;
    siot_netcore_set_command_hook(on_command, NULL);
    ESP_LOGI(TAG, "ready: this unit takes %s images from the board", PROJECT_NAME);
    if (ANY_VERSION) {
        ESP_LOGE(TAG, "TEST BUILD: this unit accepts ANY firmware version, the same or an older one. "
                      "NOT FOR PRODUCTION (docs/ota/before-production.md)");
    }
    return ESP_OK;
}
