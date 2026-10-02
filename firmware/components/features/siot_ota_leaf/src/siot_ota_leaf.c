#include "siot_ota_leaf.h"

#include <string.h>
#include <time.h>

#include "esp_event.h"
#include "esp_log.h"
#include "esp_ota_ops.h"
#include "esp_timer.h"
#include "esp_wifi.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "sdkconfig.h"

#include "siot_ota_pull.h"
#include "siot_safr.h"
#include "siot_util.h"
#include "siot_version.h"

static const char *TAG = "siot_ota";

#define FAMILY            SAFR_FAMILY_LEAF
#define PROJECT_NAME      "sempreiot-leaf"
#define IMAGE_URL         SIOT_OTA_PULL_URL "leaf.bin" /* protocol §13.5 */
#define BATTERY_MIN_PCT   60      /* §13.5 */
#define JOIN_TIMEOUT_MS   15000   /* Wi-Fi association + DHCP, per candidate AP */
#define RESULT_ACK_MS     SIOT_LEAF_ACK_WAIT_MS
#define RESULT_TRIES      3
#define BACKOFF_LONG_S    (6 * 3600) /* §13.5: next wake, then 6 h, then never */
#define BACKOFF_MAX_TRIES 5

/* TEST ONLY (docs/ota/before-production.md item 1): the same switch as the board's. */
#if CONFIG_SIOT_OTA_TEST_ANY_VERSION
#define ANY_VERSION true
#else
#define ANY_VERSION false
#endif
#if CONFIG_SIOT_OTA_ALLOW_FORCE
#define FORCE_ALLOWED true
#else
#define FORCE_ALLOWED false
#endif

/* §13.5 back-off, in RTC memory: cleared by a power cycle or another image. */
#define BACKOFF_MAGIC 0x4F544142u /* "BATO" */
typedef struct {
    uint32_t magic;
    uint8_t  sha8[8];        /* the image that failed */
    uint8_t  attempts;
    uint32_t not_before;     /* epoch seconds; 0 = the next wake is fine */
} backoff_rtc_t;
static RTC_DATA_ATTR backoff_rtc_t s_backoff;

static siot_ota_leaf_ops_t s_ops;
static siot_ota_boot_t     s_boot;
static volatile bool       s_got_ip;
static volatile bool       s_disconnected;

static int64_t now_ms(void) { return esp_timer_get_time() / 1000; }

/* ---- frames --------------------------------------------------------------------------- */

static void send_status(uint8_t state, uint8_t percent)
{
    const siot_ota_status_t st = {.state = state, .percent = percent};
    uint8_t p[SIOT_OTA_STATUS_LEN];
    s_ops.send(SAFR_MSG_OTA_STATUS, p, siot_ota_status_encode(p, &st));
}

/* OTA_RESULT with F_ACK_REQ: the parent's hop ACK closes it (§13.5). */
static bool send_result(bool ok, uint8_t reason, uint8_t detail, uint16_t awake_s)
{
    siot_ota_result_t r = {.ok = ok, .reason = reason, .awake_s = awake_s, .detail = detail};
    strlcpy(r.version, siot_version_string(), sizeof(r.version));
    uint8_t p[SAFR_MAX_PAYLOAD];
    const size_t n = siot_ota_result_encode(p, &r);
    bool acked = false;
    for (int i = 0; i < RESULT_TRIES && !acked; i++) acked = s_ops.send_acked(SAFR_MSG_OTA_RESULT, p, n, RESULT_ACK_MS);
    ESP_LOGW(TAG, "OTA_RESULT %s reason %u detail %u awake %u s, running %s: %s", ok ? "OK" : "FAILED", reason,
             detail, awake_s, r.version, acked ? "parent acknowledged" : "no parent ACK");
    return acked;
}

/* ---- boot -------------------------------------------------------------------------------- */

esp_err_t siot_ota_leaf_init(const siot_ota_leaf_ops_t *ops)
{
    if (ops == NULL || ops->send_acked == NULL || ops->send == NULL || ops->battery_pct == NULL) return ESP_ERR_INVALID_ARG;
    s_ops = *ops;
    siot_ota_pull_boot_state(&s_boot);
    if (s_backoff.magic != BACKOFF_MAGIC) memset(&s_backoff, 0, sizeof(s_backoff));
    if (s_boot.kind == SIOT_OTA_BOOT_SELFTEST) {
        ESP_LOGW(TAG, "first wake of %s: self-test — the parent's ACK confirms it, none rolls back", siot_version_string());
    }
    if (ANY_VERSION) ESP_LOGE(TAG, "TEST BUILD: this unit accepts ANY firmware version. NOT FOR PRODUCTION");
    return ESP_OK;
}

bool siot_ota_leaf_selftest_pending(void) { return s_boot.kind == SIOT_OTA_BOOT_SELFTEST; }

void siot_ota_leaf_selftest_verdict(bool parent_heard)
{
    if (s_boot.kind != SIOT_OTA_BOOT_SELFTEST) return;
#if !CONFIG_SIOT_OTA_SELFTEST_FAIL
    if (parent_heard) {
        const esp_err_t err = esp_ota_mark_app_valid_cancel_rollback();
        ESP_LOGW(TAG, "self-test passed: %s is now this unit's firmware (%s)", siot_version_string(), esp_err_to_name(err));
        s_boot.kind = SIOT_OTA_BOOT_REPORT_OK; /* said now; if the hop ACK is lost, again next wake */
        if (send_result(true, SIOT_OTA_R_NONE, 0, s_boot.awake_s)) {
            siot_ota_pull_pending_clear();
            s_boot.kind = SIOT_OTA_BOOT_PLAIN;
        }
        return;
    }
#else
    (void)parent_heard;
#endif
    ESP_LOGE(TAG, "self-test failed: no parent this wake — back to the previous firmware");
    vTaskDelay(pdMS_TO_TICKS(50));
    esp_ota_mark_app_invalid_rollback_and_reboot(); /* does not return when it works */
    ESP_LOGE(TAG, "rollback refused: no other image to go back to");
    s_boot.kind = SIOT_OTA_BOOT_PLAIN;
}

bool siot_ota_leaf_report_due(void)
{
    return s_boot.kind == SIOT_OTA_BOOT_ROLLED_BACK || s_boot.kind == SIOT_OTA_BOOT_REPORT_OK;
}

void siot_ota_leaf_report_if_due(void)
{
    switch (s_boot.kind) {
    case SIOT_OTA_BOOT_ROLLED_BACK:
        ESP_LOGE(TAG, "telling the board: %s did not make it (reason %u, detail %u), this is %s again",
                 s_boot.version, s_boot.reason, s_boot.detail, siot_version_string());
        if (send_result(false, s_boot.reason, s_boot.detail, s_boot.awake_s)) {
            siot_ota_pull_pending_clear();
            s_boot.kind = SIOT_OTA_BOOT_PLAIN;
        }
        break;
    case SIOT_OTA_BOOT_REPORT_OK:
        ESP_LOGW(TAG, "%s runs and its result was never acknowledged: reporting it again", siot_version_string());
        if (send_result(true, SIOT_OTA_R_NONE, 0, s_boot.awake_s)) {
            siot_ota_pull_pending_clear();
            s_boot.kind = SIOT_OTA_BOOT_PLAIN;
        }
        break;
    default:
        break;
    }
}

/* ---- the offer, on the wake it arrives ---------------------------------------------------------- */

static void on_wifi(void *arg, esp_event_base_t base, int32_t id, void *data)
{
    (void)arg; (void)data;
    if (base == IP_EVENT && id == IP_EVENT_STA_GOT_IP) s_got_ip = true;
    else if (base == WIFI_EVENT && id == WIFI_EVENT_STA_DISCONNECTED) s_disconnected = true;
}

/* A station on `ssid` with the installation PSK, until DHCP hands an address. */
static bool join(const char *ssid)
{
    wifi_config_t cfg = {0};
    strlcpy((char *)cfg.sta.ssid, ssid, sizeof(cfg.sta.ssid));
    strlcpy((char *)cfg.sta.password, s_ops.net_psk, sizeof(cfg.sta.password));
    cfg.sta.threshold.authmode = WIFI_AUTH_WPA2_PSK;
    s_got_ip = s_disconnected = false;
    if (esp_wifi_set_config(WIFI_IF_STA, &cfg) != ESP_OK) return false;
    ESP_LOGW(TAG, "joining %s for the pull", ssid);
    if (esp_wifi_connect() != ESP_OK) return false;
    const int64_t until = now_ms() + JOIN_TIMEOUT_MS;
    while (!s_got_ip && now_ms() < until) {
        if (s_disconnected) { s_disconnected = false; vTaskDelay(pdMS_TO_TICKS(500)); esp_wifi_connect(); }
        vTaskDelay(pdMS_TO_TICKS(100));
    }
    if (!s_got_ip) { esp_wifi_disconnect(); ESP_LOGW(TAG, "%s: no address in %d s", ssid, JOIN_TIMEOUT_MS / 1000); }
    return s_got_ip;
}

/* The station off and the radio back on the channel ESP-NOW talks on: a join
 * scans every channel, and a frame sent off-channel is lost without a word. */
static void leave_station(bool connected, uint8_t home_channel)
{
    if (connected) {
        s_disconnected = false;
        esp_wifi_disconnect();
        const int64_t until = now_ms() + 1000;
        while (!s_disconnected && now_ms() < until) vTaskDelay(pdMS_TO_TICKS(20));
    }
    if (home_channel == 0) return;
    const esp_err_t err = esp_wifi_set_channel(home_channel, WIFI_SECOND_CHAN_NONE);
    if (err != ESP_OK) ESP_LOGW(TAG, "back to channel %u: %s", home_channel, esp_err_to_name(err));
}

static void on_progress(uint8_t percent, void *ctx)
{
    (void)ctx;
    send_status(SIOT_OTA_U_DOWNLOADING, percent);
}

static bool backing_off(const siot_ota_image_t *img)
{
    if (memcmp(s_backoff.sha8, img->sha256, sizeof(s_backoff.sha8)) != 0) return false; /* another image */
    if (s_backoff.attempts >= BACKOFF_MAX_TRIES) return true;
    if (s_backoff.not_before == 0) return false;
    const time_t t = time(NULL);
    return t > 0 && (uint32_t)t < s_backoff.not_before;
}

static void note_failure(const siot_ota_image_t *img)
{
    if (memcmp(s_backoff.sha8, img->sha256, sizeof(s_backoff.sha8)) != 0) {
        memset(&s_backoff, 0, sizeof(s_backoff));
        s_backoff.magic = BACKOFF_MAGIC;
        memcpy(s_backoff.sha8, img->sha256, sizeof(s_backoff.sha8));
    }
    s_backoff.attempts++;
    const time_t t = time(NULL);
    /* the first retry is the next wake; from the second one, 6 h apart */
    s_backoff.not_before = s_backoff.attempts >= 2 && t > 0 ? (uint32_t)t + BACKOFF_LONG_S : 0;
    ESP_LOGW(TAG, "pull failed %u time(s): %s", s_backoff.attempts,
             s_backoff.attempts >= BACKOFF_MAX_TRIES ? "not again for this image" : s_backoff.not_before ? "again in 6 h" : "again next wake");
}

bool siot_ota_leaf_on_offer(uint16_t offer_msg_id, const siot_ota_image_t *img, bool alarm_wake,
                            const uint8_t parent_mac[6], int64_t wake_started_ms)
{
    uint8_t why = SIOT_OTA_R_NONE;
    if (img->family != FAMILY) why = SIOT_OTA_R_WRONG_FAMILY;
    else if (alarm_wake) why = SIOT_OTA_R_BUSY_ALARM;
    else if (s_boot.kind != SIOT_OTA_BOOT_PLAIN) why = SIOT_OTA_R_BUSY; /* an install is still being settled */
    else if (backing_off(img)) why = SIOT_OTA_R_BUSY;
    else if (s_ops.battery_pct() < BATTERY_MIN_PCT) why = SIOT_OTA_R_LOW_BATTERY;
    else why = siot_ota_accept_version(siot_version_string(), img->version,
                                       ANY_VERSION || (img->flags & SIOT_OTA_F_FORCE) != 0, ANY_VERSION || FORCE_ALLOWED);

    /* The answer: a plain ACK the parent forwards up; the board reads it as the offer's ACK (§13.5). */
    const uint8_t ack[4] = {(uint8_t)(offer_msg_id >> 8), (uint8_t)offer_msg_id,
                            why == SIOT_OTA_R_NONE ? SAFR_ACK_OK : SAFR_ACK_ERROR, why};
    s_ops.send(SAFR_MSG_ACK, ack, sizeof(ack));
    if (why != SIOT_OTA_R_NONE) {
        ESP_LOGW(TAG, "firmware offer %s refused: reason %u (battery %u %%)", img->version, why, s_ops.battery_pct());
        return false;
    }
    ESP_LOGW(TAG, "firmware offer %s taken (%lu B): pulling it now, this wake", img->version, (unsigned long)img->size);
    send_status(SIOT_OTA_U_DOWNLOADING, 0);

    uint8_t home_channel = 0;
    wifi_second_chan_t second = WIFI_SECOND_CHAN_NONE;
    if (esp_wifi_get_channel(&home_channel, &second) != ESP_OK) home_channel = 0;

    esp_event_handler_instance_t h_ip = NULL, h_wifi = NULL;
    esp_event_handler_instance_register(IP_EVENT, IP_EVENT_STA_GOT_IP, on_wifi, NULL, &h_ip);
    esp_event_handler_instance_register(WIFI_EVENT, WIFI_EVENT_STA_DISCONNECTED, on_wifi, NULL, &h_wifi);

    /* The parent's SoftAP first (it is within reach by construction: ESP-NOW
     * works), the board's own AP as the fallback. SSID form: link_mesh_node.c. */
    char ssid[33];
    snprintf(ssid, sizeof(ssid), "%.22s-%02x%02x%02x", s_ops.net_ssid, parent_mac[3], parent_mac[4], parent_mac[5]);
    bool joined = join(ssid);
    if (!joined) joined = join(s_ops.net_ssid);

    siot_ota_reason_t r = SIOT_OTA_R_HTTP_ERR;
    if (joined) r = siot_ota_pull_install(img, IMAGE_URL, PROJECT_NAME, on_progress, NULL, NULL);
    const uint16_t awake_s = (uint16_t)((now_ms() - wake_started_ms + 999) / 1000);
    if (r != SIOT_OTA_R_NONE) {
        ESP_LOGE(TAG, "update to %s failed: reason %u after %u s awake, still running %s", img->version, r, awake_s,
                 siot_version_string());
        note_failure(img);
    }
    /* The outcome is said while the station is still up, as every progress
     * status was: the board must hear it, or it shows "downloading 100 %"
     * until its deadline. A leaf that never joined says it once back on its channel. */
    bool told = false;
    if (joined) {
        if (r == SIOT_OTA_R_NONE) send_status(SIOT_OTA_U_REBOOTING, 100);
        else told = send_result(false, (uint8_t)r, 0, awake_s);
    }
    leave_station(joined, home_channel);
    esp_event_handler_instance_unregister(IP_EVENT, IP_EVENT_STA_GOT_IP, h_ip);
    esp_event_handler_instance_unregister(WIFI_EVENT, WIFI_EVENT_STA_DISCONNECTED, h_wifi);

    if (r == SIOT_OTA_R_NONE) {
        siot_ota_pull_pending_set_awake(awake_s);
        memset(&s_backoff, 0, sizeof(s_backoff));
        ESP_LOGW(TAG, "%s installed after %u s awake: sleeping, the next wake runs it", img->version, awake_s);
        return true;
    }
    if (!told) send_result(false, (uint8_t)r, 0, awake_s);
    return false;
}
