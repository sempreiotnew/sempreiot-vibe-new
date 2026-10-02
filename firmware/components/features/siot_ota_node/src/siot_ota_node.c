#include "siot_ota_node.h"

#include <string.h>

#include "esp_log.h"
#include "esp_ota_ops.h"
#include "esp_system.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "freertos/task.h"
#include "sdkconfig.h"

#include "siot_evbus.h"
#include "siot_link.h"
#include "siot_netcore.h"
#include "siot_ota_proto.h"
#include "siot_ota_pull.h"
#include "siot_safr.h"
#include "siot_util.h"
#include "siot_version.h"

static const char *TAG = "siot_ota";

#define FAMILY            SAFR_FAMILY_NODE
#define PROJECT_NAME      "sempreiot-node"
#define IMAGE_URL         SIOT_OTA_PULL_URL "node.bin" /* protocol §13.4 */
#define RESULT_ACK_MS     3000   /* one try of OTA_RESULT waits this long for an ACK */
#define RESULT_TRIES      3      /* tries per call of send_result(): 9 s at most, never longer — an offer
                                    must be worked at once, so an unacknowledged report is retried from
                                    the task's idle loop (REPORT_RETRY_MS) until the board answers */
#define REPORT_RETRY_MS   20000
#define SELFTEST_SAY_MS   10000  /* OTA_STATUS selftest is repeated this often while waiting */

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
static siot_ota_boot_t s_boot;        /* what this boot means (siot_ota_pull) */
static volatile uint16_t s_result_msg_id;
static volatile bool s_result_acked;
/* The last OTA_RESULT nobody acknowledged: said again from the idle loop. */
static bool    s_report_due;
static bool    s_report_ok;
static uint8_t s_report_reason, s_report_detail;
static bool    s_report_clears_pending; /* acknowledged → the pending record goes */

static int64_t now_ms(void) { return esp_timer_get_time() / 1000; }

static bool board_heard(void)
{
    return siot_link_mesh_level() > 0 && siot_netcore_board_reachable();
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
 * (§13.4): RESULT_TRIES here, then from the idle loop (report_again) — this
 * task must stay free to take the next offer. Returns true when acknowledged. */
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

/* The result to tell the board, now and — if nobody acknowledges it — again
 * from the idle loop every REPORT_RETRY_MS. Once acknowledged, a report that
 * settles an install erases the pending record, so a lost report is made
 * again on the next boot rather than never. */
static void report_done(void)
{
    s_report_due = false;
    if (s_report_clears_pending) siot_ota_pull_pending_clear();
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

static void on_progress(uint8_t percent, void *ctx)
{
    (void)ctx;
    send_status(SIOT_OTA_U_DOWNLOADING, percent);
}

static bool on_abort(void *ctx)
{
    (void)ctx;
    return siot_netcore_alarm_active();
}

/* ---- self-test (the same task) ---------------------------------------------------------- */

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

static void ota_task(void *arg)
{
    (void)arg;
    switch (s_boot.kind) {
    case SIOT_OTA_BOOT_SELFTEST:
        run_selftest();
        break;
    case SIOT_OTA_BOOT_ROLLED_BACK:
        ESP_LOGE(TAG, "telling the board: %s did not make it (reason %u, detail %u), this is %s again",
                 s_boot.version, s_boot.reason, s_boot.detail, siot_version_string());
        report(false, s_boot.reason, s_boot.detail, true);
        break;
    case SIOT_OTA_BOOT_REPORT_OK:
        ESP_LOGW(TAG, "%s runs and its result was never acknowledged: reporting it again", siot_version_string());
        report(true, SIOT_OTA_R_NONE, 0, true);
        break;
    default:
        break;
    }
    for (;;) {
        /* An offer wakes this at once; otherwise an unacknowledged report is said again. */
        if (ulTaskNotifyTake(pdTRUE, pdMS_TO_TICKS(REPORT_RETRY_MS)) == 0) {
            report_again();
            continue;
        }
        send_status(SIOT_OTA_U_DOWNLOADING, 0);
        const siot_ota_reason_t why = siot_ota_pull_install(&s_offer, IMAGE_URL, PROJECT_NAME, on_progress,
                                                            on_abort, NULL);
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
    siot_ota_pull_boot_state(&s_boot);
    s_selftest = s_boot.kind == SIOT_OTA_BOOT_SELFTEST;
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
