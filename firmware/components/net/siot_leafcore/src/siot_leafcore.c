/* siot_leafcore — protocol §12 on the ESP32-S3. Layout of this file:
 *   1. RTC state + NVS mirror        4. discovery / bind (§12.3)
 *   2. Wi-Fi + ESP-NOW transport     5. heartbeat cycle (§12.2, §12.4–§12.6)
 *   3. SAFR handlers                 6. button verdicts (§12.8), setup (§12.9), sleep
 * Every number comes from siot_leaf_proto.h / Kconfig, never from here. */
#include "siot_leafcore.h"

#include <string.h>
#include <sys/time.h>
#include <time.h>

#include "driver/rtc_io.h"
#include "esp_event.h"
#include "esp_log.h"
#include "esp_netif.h"
#include "esp_now.h"
#include "esp_sleep.h"
#include "esp_system.h"
#include "esp_timer.h"
#include "esp_wifi.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/semphr.h"
#include "freertos/task.h"
#include "nvs.h"
#include "sdkconfig.h"

#include "siot_board_def.h"
#include "siot_config.h"
#include "siot_evbus.h"
#include "siot_hal_gpio.h"
#include "siot_identity.h"
#include "siot_leaf_proto.h"
#include "siot_provisioning.h"
#include "siot_safr.h"
#include "siot_sensor.h"
#include "siot_ui_led.h"
#include "siot_util.h"
#include "siot_version.h"

static const char *TAG = "siot_leaf";

#define ESPNOW_TYPE        0xD2      /* same prefix as siot_survey: Mesh-Lite routes on it */
#define RX_QUEUE_LEN       8
#define SEND_WAIT_MS       50        /* MAC-layer ACK arrives well under 10 ms */
#define RTC_MAGIC          0x4C454146u /* "LEAF" */
#define HB_INTERVAL_MS     ((uint32_t)CONFIG_SIOT_LEAF_HB_INTERVAL_S * 1000u)
#define SURVEY_COPIES      4
#define SURVEY_SPACING_MS  1200
#define SURVEY_WINDOW_MS   4500
#define HOLD_CHECK_MS      5500      /* button still held after a wake: let the 5 s factory-reset hold run */
#define INSTALL_WAKE_MS    1000      /* §13.5: an image just installed runs (and self-tests) 1 s later */
#define NVS_NS             "siot_leaf"
#define NVS_KEY_OUTBOX     "outbox"
#define NVS_KEY_RTC_MIRROR "rtc"     /* the whole RTC state, kept across a firmware change (§13.5) */

/* ---- 1. state ------------------------------------------------------------ */

typedef enum { BIND_NONE = 0, BIND_BOUND, BIND_COMM_FAULT } bind_t;

typedef struct {
    uint32_t magic;
    uint16_t system_id;         /* the code this state belongs to: re-provisioned → fresh state */
    uint8_t  bind;              /* bind_t */
    uint8_t  parent_mac[6];     /* SAFR SRC_MAC of the parent (its STA MAC) */
    uint8_t  parent_peer[6];    /* ESP-NOW address the offer came from (unicast target) */
    uint8_t  parent_layer;      /* 0xFF = not on a mesh */
    int8_t   parent_link;       /* dBm, the weaker direction at bind time */
    uint8_t  channel;
    uint8_t  misses;
    bool     announced;         /* NAME_ANNOUNCE sent once after provisioning (§12.9) */
    bool     verdict_pending;   /* first wake with a code: show the §12.8 verdict */
    bool     no_path;           /* last ACK said NO_PATH */
    bool     heard_any;         /* last probe got offers (none online) → probe every wake */
    uint16_t wakes_since_probe;
    uint16_t msg_id;            /* last MSG_ID used: continues across wakes (spec §12.2) */
    uint32_t wake_count;
    siot_leaf_outbox_t outbox;
} leaf_rtc_t;

static RTC_DATA_ATTR leaf_rtc_t s_rtc;

typedef struct {
    uint8_t len;
    uint8_t src[6];
    int8_t  rssi;
    uint8_t data[SAFR_MAX_FRAME];
} rx_item_t;

static QueueHandle_t     s_rx_queue;
static SemaphoreHandle_t s_send_sem;
static volatile bool     s_send_ok;
static bool              s_wifi_inited;
static bool              s_transport_up;
static uint8_t           s_my_mac[6];
static int               s_button_pin = SIOT_PIN_NONE;
static const siot_installation_t *s_code;

/* frame being dispatched (pump → handler, same task) */
static uint8_t s_rx_src[6];
static int8_t  s_rx_rssi;

/* discovery */
static bool                  s_probing;
static uint8_t               s_probe_purpose;
static siot_leaf_candidate_t s_cand[SIOT_LEAF_CANDIDATES_MAX];
static uint8_t               s_cand_n;
static bool                  s_led_allowed;  /* pulses only in §12.8 flows */

/* acks */
static uint16_t        s_ack_wanted;
static bool            s_ack_hop;      /* parent acknowledged s_ack_wanted */
static bool            s_ack_central;  /* the central acknowledged s_ack_wanted (walk-test cyan) */
static siot_leaf_ack_t s_ack_last;
static int             s_mailbox_left; /* frames the parent said it would send */
static int             s_mailbox_total; /* DETAIL of the ACK that opened the drain */
static int64_t         s_stay_awake_until_ms;

/* wake cause in LIGHT / NONE mode (DEEP asks esp_sleep) */
static esp_sleep_wakeup_cause_t s_sim_cause = ESP_SLEEP_WAKEUP_UNDEFINED;
static volatile bool s_tap_flag;
static siot_leafcore_ota_t s_ota; /* §13.5 hooks, all optional */

static int64_t now_ms(void) { return esp_timer_get_time() / 1000; }

static uint32_t epoch_now(void)
{
    const time_t t = time(NULL);
    return t > 1600000000 ? (uint32_t)t : 0; /* before 2020 = no clock */
}

static const char *cause_name(esp_sleep_wakeup_cause_t c)
{
    switch (c) {
    case ESP_SLEEP_WAKEUP_TIMER: return "timer";
    case ESP_SLEEP_WAKEUP_EXT1:  return "button";
    default:                     return "power-on";
    }
}

static void outbox_save(void)
{
    nvs_handle_t h;
    if (nvs_open(NVS_NS, NVS_READWRITE, &h) != ESP_OK) return;
    if (nvs_set_blob(h, NVS_KEY_OUTBOX, &s_rtc.outbox, sizeof(s_rtc.outbox)) == ESP_OK) nvs_commit(h);
    nvs_close(h);
}

static void outbox_load(void)
{
    nvs_handle_t h;
    if (nvs_open(NVS_NS, NVS_READONLY, &h) != ESP_OK) return;
    size_t len = sizeof(s_rtc.outbox);
    siot_leaf_outbox_t tmp;
    if (nvs_get_blob(h, NVS_KEY_OUTBOX, &tmp, &len) == ESP_OK && len == sizeof(tmp) &&
        tmp.count <= SIOT_LEAF_OUTBOX_CAP && tmp.head < SIOT_LEAF_OUTBOX_CAP) {
        s_rtc.outbox = tmp;
        ESP_LOGI(TAG, "outbox restored from NVS: %u event(s)", tmp.count);
    }
    nvs_close(h);
}

/* §13.5: the wake after a pull boots ANOTHER image, whose RTC variables may
 * not sit where this one's do — the parent, channel and bind would read as
 * garbage and the leaf would come up as if freshly provisioned (and run the
 * installer's verdict instead of its self-test). So the state is mirrored to
 * NVS just before that boot (and before a rollback), and taken back once. */
static void rtc_mirror_save(void)
{
    s_rtc.msg_id = siot_safr_last_msg_id();
    nvs_handle_t h;
    if (nvs_open(NVS_NS, NVS_READWRITE, &h) != ESP_OK) return;
    if (nvs_set_blob(h, NVS_KEY_RTC_MIRROR, &s_rtc, sizeof(s_rtc)) == ESP_OK) nvs_commit(h);
    nvs_close(h);
    ESP_LOGI(TAG, "RTC state mirrored to NVS for the next image");
}

static bool rtc_mirror_take(void)
{
    nvs_handle_t h;
    if (nvs_open(NVS_NS, NVS_READWRITE, &h) != ESP_OK) return false;
    size_t len = sizeof(s_rtc);
    leaf_rtc_t tmp;
    const bool ok = nvs_get_blob(h, NVS_KEY_RTC_MIRROR, &tmp, &len) == ESP_OK && len == sizeof(tmp) &&
                    tmp.magic == RTC_MAGIC && tmp.system_id == s_code->system_id;
    if (nvs_get_blob(h, NVS_KEY_RTC_MIRROR, NULL, &len) == ESP_OK) { /* once: it belongs to that one boot */
        nvs_erase_key(h, NVS_KEY_RTC_MIRROR);
        nvs_commit(h);
    }
    nvs_close(h);
    if (ok) {
        s_rtc = tmp;
        /* The mirror is written only before a boot into ANOTHER image (the
         * new one, or the old one after a rollback): say again what this
         * unit runs, on this wake — the tablet and the board's table learn
         * the version from NAME_ANNOUNCE (§7.11). */
        s_rtc.announced = false;
        ESP_LOGW(TAG, "RTC state taken back from NVS (another image wrote it): bound=%u ch=%u",
                 s_rtc.bind == BIND_BOUND, s_rtc.channel);
    }
    return ok;
}

static void rtc_reset(void)
{
    memset(&s_rtc, 0, sizeof(s_rtc));
    s_rtc.magic = RTC_MAGIC;
    s_rtc.system_id = s_code->system_id;
    s_rtc.parent_layer = 0xFF;
    s_rtc.parent_link = (int8_t)SAFR_NA_RSSI;
    s_rtc.verdict_pending = true;
    /* No RTC state to continue from (power-on): start away from the ids the
     * previous life may have used in the last 30 s. */
    s_rtc.msg_id = (uint16_t)(siot_config_boot_ctr() << 4);
    siot_leaf_outbox_init(&s_rtc.outbox);
    outbox_load();
}

/* ---- 2. transport ---------------------------------------------------------- */

static void on_espnow_recv(const esp_now_recv_info_t *info, const uint8_t *data, int len)
{
    if (len < 1 + SAFR_MIN_FRAME || len - 1 > SAFR_MAX_FRAME || data[0] != ESPNOW_TYPE) return;
    if (data[1] != SAFR_SOF) return;
    rx_item_t item;
    item.len = (uint8_t)(len - 1);
    memcpy(item.data, data + 1, item.len);
    memcpy(item.src, info->src_addr, 6);
    item.rssi = info->rx_ctrl ? (int8_t)info->rx_ctrl->rssi : (int8_t)SAFR_NA_RSSI;
    xQueueSend(s_rx_queue, &item, 0);
}

static void on_espnow_send(const esp_now_send_info_t *tx_info, esp_now_send_status_t status)
{
    (void)tx_info;
    s_send_ok = status == ESP_NOW_SEND_SUCCESS;
    xSemaphoreGive(s_send_sem);
}

static esp_err_t ensure_peer(const uint8_t mac[6])
{
    if (esp_now_is_peer_exist(mac)) return ESP_OK;
    esp_now_peer_info_t peer;
    memset(&peer, 0, sizeof(peer));
    memcpy(peer.peer_addr, mac, 6);
    peer.channel = 0;
    peer.ifidx = WIFI_IF_STA;
    peer.encrypt = false; /* SAFR authenticates and encrypts (§12.1) */
    const esp_err_t err = esp_now_add_peer(&peer);
    return err == ESP_ERR_ESPNOW_EXIST ? ESP_OK : err;
}

static esp_err_t wifi_up(uint8_t channel)
{
    esp_err_t err;
    if (!s_wifi_inited) {
        if ((err = esp_netif_init()) != ESP_OK) return err;
        err = esp_event_loop_create_default();
        if (err != ESP_OK && err != ESP_ERR_INVALID_STATE) return err; /* evbus owns it */
        if (esp_netif_create_default_wifi_sta() == NULL) return ESP_FAIL;
        wifi_init_config_t cfg = WIFI_INIT_CONFIG_DEFAULT();
        if ((err = esp_wifi_init(&cfg)) != ESP_OK) return err;
        if ((err = esp_wifi_set_storage(WIFI_STORAGE_RAM)) != ESP_OK) return err;
        if ((err = esp_wifi_set_mode(WIFI_MODE_STA)) != ESP_OK) return err;
        s_wifi_inited = true;
    }
    if ((err = esp_wifi_start()) != ESP_OK) return err;
    if ((err = esp_wifi_set_ps(WIFI_PS_NONE)) != ESP_OK) return err;
    if ((err = esp_wifi_set_channel(channel, WIFI_SECOND_CHAN_NONE)) != ESP_OK) return err;
    err = esp_now_init();
    if (err != ESP_OK && err != ESP_ERR_ESPNOW_EXIST) return err;
    if ((err = esp_now_register_recv_cb(on_espnow_recv)) != ESP_OK) return err;
    if ((err = esp_now_register_send_cb(on_espnow_send)) != ESP_OK) return err;
    if ((err = ensure_peer(SAFR_BCAST_MAC)) != ESP_OK) return err;
    s_transport_up = true;
    return ESP_OK;
}

static void wifi_down(void)
{
    if (!s_transport_up) return;
    esp_now_deinit();
    esp_wifi_stop();
    s_transport_up = false;
}

/* Unicast: true = the 802.11 MAC ACK came back (the hop proof, §12.1).
 * Broadcast: true = the frame left. */
static bool espnow_send_wait(const uint8_t peer[6], const uint8_t *frame, size_t len)
{
    if (!s_transport_up || len + 1 > ESP_NOW_MAX_DATA_LEN) return false;
    if (ensure_peer(peer) != ESP_OK) return false;
    uint8_t buf[ESP_NOW_MAX_DATA_LEN];
    buf[0] = ESPNOW_TYPE;
    memcpy(&buf[1], frame, len);
    xSemaphoreTake(s_send_sem, 0); /* drain a stale give */
    s_send_ok = false;
    if (esp_now_send(peer, buf, len + 1) != ESP_OK) return false;
    if (xSemaphoreTake(s_send_sem, pdMS_TO_TICKS(SEND_WAIT_MS)) != pdTRUE) return false;
    return s_send_ok;
}

static bool s_last_tx_ok;

/* siot_safr's TX sink: probes go to broadcast, everything else to the parent
 * (§12.1 unicast); with no parent, broadcast (the alarm fallback also lands here). */
static void tx_sink(const uint8_t *frame, size_t len, const uint8_t dst_mac[6], void *ctx)
{
    (void)ctx;
    (void)dst_mac; /* SAFR DST (central / device) is routing for the mesh; the ESP-NOW hop is always the parent */
    const uint8_t type = frame[4];
    const bool to_parent = type != SAFR_MSG_PARENT_PROBE && s_rtc.bind == BIND_BOUND;
    const uint8_t *peer = to_parent ? s_rtc.parent_peer : SAFR_BCAST_MAC;
    s_last_tx_ok = espnow_send_wait(peer, frame, len);
    if (s_led_allowed && s_last_tx_ok && type == SAFR_MSG_EVENT) { /* §12.8: blue = the test event left */
        const siot_evt_frame_t ev = {.msg_type = type};
        siot_evbus_post(SIOT_EVT_SAFR_TX, &ev, sizeof(ev));
    }
    ESP_LOGD(TAG, "tx type 0x%02X → %s: %s", type, to_parent ? "parent" : "bcast",
             s_last_tx_ok ? "ok" : "NO MAC ACK");
}

/* Runs the RX queue for `ms` (handlers run here, in the calling task). */
static void pump(uint32_t ms)
{
    const int64_t until = now_ms() + ms;
    for (;;) {
        const int64_t left = until - now_ms();
        if (left <= 0) return;
        rx_item_t item;
        if (xQueueReceive(s_rx_queue, &item, pdMS_TO_TICKS((uint32_t)left)) != pdTRUE) return;
        memcpy(s_rx_src, item.src, 6);
        s_rx_rssi = item.rssi;
        siot_safr_rx(item.data, item.len);
    }
}

/* ---- 3. handlers ----------------------------------------------------------- */

static uint8_t leaf_level(void) { return s_rtc.parent_layer == 0xFF ? 2 : (uint8_t)(s_rtc.parent_layer + 1); }

static void send_ack(uint16_t acked_msg_id, uint8_t status, const uint8_t dst[6])
{
    uint8_t p[4] = {(uint8_t)(acked_msg_id >> 8), (uint8_t)acked_msg_id, status, 0x00};
    siot_safr_send(dst, SAFR_MSG_ACK, siot_safr_next_msg_id(), 0, p, sizeof(p));
}

static void apply_leaf_ack(const siot_leaf_ack_t *a)
{
    s_rtc.no_path = a->no_path;
    if (a->has_ext) {
        if (a->epoch != 0) {
            struct timeval tv = {.tv_sec = (time_t)a->epoch, .tv_usec = 0};
            settimeofday(&tv, NULL);
        }
        if (a->channel >= 1 && a->channel <= 13 && a->channel != s_rtc.channel) {
            ESP_LOGW(TAG, "parent says channel %u (we had %u): switching next wake", a->channel, s_rtc.channel);
            s_rtc.channel = a->channel;
        }
    }
    if (a->pending) {
        s_mailbox_left = a->detail > SIOT_LEAF_MAILBOX_DRAIN_MAX ? SIOT_LEAF_MAILBOX_DRAIN_MAX : a->detail;
        s_mailbox_total = s_mailbox_left;
        ESP_LOGW(TAG, "mailbox: parent holds %u frame(s) for me — staying awake for up to %d (budget %lu ms left)",
                 a->detail, s_mailbox_left, (unsigned long)siot_leaf_budget_left_ms(now_ms(), SIOT_LEAF_WAKE_BUDGET_MS));
    } else {
        s_mailbox_total = 0;
    }
}

static void on_ack(const siot_safr_frame_t *f, const uint8_t *raw, size_t raw_len, bool dup, void *ctx)
{
    (void)raw; (void)raw_len; (void)dup; (void)ctx;
    siot_leaf_ack_t a;
    if (!siot_leaf_ack_parse(f->payload, f->payload_len, &a)) return;
    char src[SIOT_MAC_STR_LEN];
    const bool from_central = siot_mac_eq(f->src_mac, SAFR_CENTRAL_MAC);
    const bool from_parent  = s_rtc.bind == BIND_BOUND && siot_mac_eq(f->src_mac, s_rtc.parent_mac);
    ESP_LOGI(TAG, "ACK msg_id %u status %u%s%s from %s%s", a.acked_msg_id, a.code,
             a.pending ? " PENDING" : "", a.no_path ? " NO_PATH" : "", siot_mac_to_str(f->src_mac, src),
             from_central ? " (central)" : from_parent ? " (parent)" : "");
    if (s_mailbox_left > 0 && !from_parent) { /* a frame the parent kept for me (§12.5) */
        s_mailbox_left--;
        ESP_LOGW(TAG, "mailbox: frame %d/%d = ACK from %s for msg_id %u%s", s_mailbox_total - s_mailbox_left, s_mailbox_total,
                 from_central ? "the central" : "the board", a.acked_msg_id,
                 a.acked_msg_id == s_ack_wanted ? " (the one I am waiting for)" : " (an earlier event)");
    }
    if (a.acked_msg_id != s_ack_wanted) return;
    if (from_central) s_ack_central = true;
    if (from_parent || (!from_central && s_rtc.bind != BIND_BOUND)) {
        s_ack_hop = true;
        s_ack_last = a;
        apply_leaf_ack(&a);
    }
}

static void on_offer(const siot_safr_frame_t *f, const uint8_t *raw, size_t raw_len, bool dup, void *ctx)
{
    (void)raw; (void)raw_len; (void)dup; (void)ctx;
    if (!s_probing || f->payload_len < 3 || f->payload[0] != s_probe_purpose) return;
    const int8_t link = siot_leaf_link((int8_t)f->payload[1], s_rx_rssi);
    for (uint8_t i = 0; i < s_cand_n; i++) {
        if (siot_mac_eq(s_cand[i].mac, f->src_mac)) { /* a repeated copy: keep the better reading */
            if (link > s_cand[i].link) s_cand[i].link = link;
            return;
        }
    }
    char src[SIOT_MAC_STR_LEN];
    ESP_LOGI(TAG, "offer from %s: they saw %d dBm, we see %d dBm → link %d, layer %u",
             siot_mac_to_str(f->src_mac, src), (int8_t)f->payload[1], s_rx_rssi, link, f->payload[2]);
    if (s_cand_n < SIOT_LEAF_CANDIDATES_MAX) {
        siot_leaf_candidate_t *c = &s_cand[s_cand_n++];
        memcpy(c->mac, f->src_mac, 6);
        memcpy(c->peer, s_rx_src, 6);
        c->link = link;
        c->layer = f->payload[2];
    }
    /* Survey only, and through siot_ui_led like a node's (reference §3.7 row
     * 7.7): one blink per answering unit in its link colour, a dark gap after
     * each. A parent discovery shows nothing — its result is the walk test. */
    if (s_led_allowed && s_probe_purpose == SAFR_PROBE_SURVEY) {
        const siot_evt_rssi_t ans = {.rssi = link};
        siot_evbus_post(SIOT_EVT_SURVEY_ANSWER, &ans, sizeof(ans));
    }
}

static void build_event(uint8_t *p, uint8_t evt_type, uint8_t evt_code)
{
    siot_sensor_reading_t r;
    siot_sensor_read(&r);
    p[0] = evt_type;
    p[1] = evt_code;
    siot_put_u32(&p[2], epoch_now());
    p[6] = SAFR_PWR_ON_BATTERY;
    p[7] = siot_sensor_battery_pct();
    siot_put_u16(&p[8], r.valid ? r.smoke_raw : SAFR_NA_U16);
    siot_put_u16(&p[10], (uint16_t)(r.valid ? r.temp_x10 : SAFR_NA_I16));
    p[12] = r.valid ? r.humidity : SAFR_NA_U8;
    p[13] = 0;
    p[14] = 0;
    siot_put_u16(&p[15], siot_config_dev_seq_next());
}

static bool emit_name_announce(void)
{
    uint8_t p[1 + SIOT_NAME_MAX_LEN + 1 + SIOT_ZONE_MAX_LEN + 1 + SAFR_PRODUCT_MAX_LEN];
    const uint8_t name_len = (uint8_t)strnlen(s_code->name, SIOT_NAME_MAX_LEN);
    const uint8_t zone_len = (uint8_t)strnlen(s_code->zone, SIOT_ZONE_MAX_LEN);
    size_t off = 0;
    p[off++] = name_len; memcpy(&p[off], s_code->name, name_len); off += name_len;
    p[off++] = zone_len; memcpy(&p[off], s_code->zone, zone_len); off += zone_len;
    p[off++] = SAFR_ROLE_LEAF;
    off += siot_safr_put_product(&p[off], siot_board_def_product(), siot_board_def()->hw_rev,
                                 siot_version_string()); /* v3.5: what this unit is and runs */
    return siot_safr_send(SAFR_BCAST_MAC, SAFR_MSG_NAME_ANNOUNCE, siot_safr_next_msg_id(), 0, p, off) == ESP_OK
           && s_last_tx_ok;
}

static bool for_me(const siot_safr_frame_t *f)
{
    return siot_mac_eq(f->dst_mac, s_my_mac) || siot_mac_is_bcast(f->dst_mac);
}

static void on_command(const siot_safr_frame_t *f, const uint8_t *raw, size_t raw_len, bool dup, void *ctx)
{
    (void)raw; (void)raw_len; (void)ctx;
    if (!for_me(f) || f->payload_len < 2) return;
    const bool from_mailbox = s_mailbox_left > 0;
    if (from_mailbox) {
        s_mailbox_left--;
        ESP_LOGW(TAG, "mailbox: frame %d/%d = COMMAND 0x%02X msg_id %u", s_mailbox_total - s_mailbox_left, s_mailbox_total,
                 f->payload[0], f->msg_id);
    }
    const uint8_t cmd = f->payload[0];
    const size_t alen = f->payload[1];
    const uint8_t *args = &f->payload[2];
    if (2 + alen > f->payload_len) return;
    const bool ack_req = (f->flags & SAFR_F_ACK_REQ) != 0;
    ESP_LOGI(TAG, "COMMAND 0x%02X msg_id %u%s", cmd, f->msg_id, dup ? " (dup)" : "");
    if (dup) { if (ack_req) send_ack(f->msg_id, SAFR_ACK_OK, f->src_mac); return; }

    uint8_t status = SAFR_ACK_OK;
    switch (cmd) {
    case SAFR_CMD_IDENTIFY: {
        const uint8_t s = alen >= 1 && args[0] ? args[0] : SIOT_LED_IDENTIFY_DEFAULT_S;
        const siot_evt_identify_t ev = {.seconds = s};
        siot_evbus_post(SIOT_EVT_IDENTIFY, &ev, sizeof(ev));
        s_stay_awake_until_ms = now_ms() + (int64_t)s * 1000 + 200;
        break;
    }
    case SAFR_CMD_SET_DEVICE: {
        if (alen < 8 || !siot_mac_eq(args, s_my_mac)) { status = SAFR_ACK_ERROR; break; }
        const uint8_t nl = args[6];
        if (nl > SIOT_NAME_MAX_LEN || 7 + nl + 1 > alen) { status = SAFR_ACK_ERROR; break; }
        const uint8_t zl = args[7 + nl];
        if (zl > SIOT_ZONE_MAX_LEN || 8 + nl + zl > alen) { status = SAFR_ACK_ERROR; break; }
        siot_installation_t inst = *s_code;
        memcpy(inst.name, &args[7], nl); inst.name[nl] = 0;
        memcpy(inst.zone, &args[8 + nl], zl); inst.zone[zl] = 0;
        if (siot_config_save_code(&inst) != ESP_OK) { status = SAFR_ACK_ERROR; break; }
        s_code = siot_config_code();
        ESP_LOGW(TAG, "SET_DEVICE: now \"%s\" / \"%s\"", inst.name, inst.zone);
        s_rtc.announced = false; /* re-announce below */
        break;
    }
    case SAFR_CMD_DECOMMISSION:
        if (alen < 6 || !siot_mac_eq(f->dst_mac, s_my_mac) || !siot_mac_eq(args, s_my_mac)) { status = SAFR_ACK_ERROR; break; }
        send_ack(f->msg_id, SAFR_ACK_OK, f->src_mac);
        ESP_LOGW(TAG, "DECOMMISSION: erasing the code, back to setup");
        vTaskDelay(pdMS_TO_TICKS(300));
        siot_config_factory_reset();
        esp_restart();
    case SAFR_CMD_TEST:
    case SAFR_CMD_RESET:
    case SAFR_CMD_SILENCE:
    case SAFR_CMD_RELAY_SET:
    case SAFR_CMD_LINK_CHECK:
        break; /* acknowledged; alarm/relay behaviour is the next increment (brief step 4) */
    default:
        status = SAFR_ACK_ERROR;
    }
    if (ack_req) send_ack(f->msg_id, status, f->src_mac);
    if (cmd == SAFR_CMD_SET_DEVICE && status == SAFR_ACK_OK && emit_name_announce()) s_rtc.announced = true;
}

/* ---- 4. discovery ------------------------------------------------------------ */

/* Broadcasts `copies` probes `spacing_ms` apart (same MSG_ID, fresh MSG_CTR)
 * and listens `window_ms` in all; returns the number of distinct answerers. */
static uint8_t probe(uint8_t purpose, uint8_t copies, uint32_t spacing_ms, uint32_t window_ms)
{
    s_cand_n = 0;
    s_probing = true;
    s_probe_purpose = purpose;
    const uint16_t msg_id = siot_safr_next_msg_id();
    const uint8_t p[1] = {purpose};
    const int64_t start = now_ms();
    for (uint8_t i = 0; i < copies; i++) {
        siot_safr_send(SAFR_BCAST_MAC, SAFR_MSG_PARENT_PROBE, msg_id, 0, p, sizeof(p));
        if (i + 1 < copies) pump(spacing_ms);
    }
    const int64_t left = (int64_t)window_ms - (now_ms() - start);
    if (left > 0) pump((uint32_t)left);
    s_probing = false;
    /* What the radio heard while the window was open: "foreign" = units
     * answering under another installation's SYSTEM_ID (wrong installation on
     * one side); "auth" = same SYSTEM_ID, different key; 0 frames = nobody on
     * this channel heard us or nobody is there. */
    siot_safr_stats_t st;
    siot_safr_get_stats(&st);
    ESP_LOGW(TAG, "probe purpose %u: %u offer(s); radio rx %lu frame(s): ok %lu, foreign %lu, auth-fail %lu, bad %lu, replay %lu",
             purpose, s_cand_n, (unsigned long)st.rx_frames, (unsigned long)st.rx_ok, (unsigned long)st.foreign,
             (unsigned long)st.auth, (unsigned long)st.bad_frame, (unsigned long)st.replay);
    siot_safr_reset_stats();
    return s_cand_n;
}

static void bind_to(const siot_leaf_candidate_t *c)
{
    s_rtc.bind = BIND_BOUND;
    memcpy(s_rtc.parent_mac, c->mac, 6);
    memcpy(s_rtc.parent_peer, c->peer, 6);
    s_rtc.parent_layer = c->layer;
    s_rtc.parent_link = c->link;
    s_rtc.misses = 0;
    s_rtc.no_path = false;
    siot_safr_set_level(leaf_level());
    char m[SIOT_MAC_STR_LEN];
    ESP_LOGW(TAG, "bound to %s (layer %u, link %d dBm%s)", siot_mac_to_str(c->mac, m), c->layer, c->link,
             c->link < SIOT_LEAF_BIND_MIN_DBM ? ", WEAK" : "");
}

static void emit_topology(void)
{
    uint8_t p[SAFR_MAX_PAYLOAD];
    siot_put_u32(&p[0], epoch_now());
    p[4] = SAFR_ROLE_LEAF;
    p[5] = leaf_level();
    memcpy(&p[6], s_rtc.parent_mac, 6);
    p[12] = (uint8_t)s_rtc.parent_link;
    p[13] = s_cand_n;
    size_t off = 14;
    for (uint8_t i = 0; i < s_cand_n && off + 7 <= SAFR_MAX_PAYLOAD; i++) {
        memcpy(&p[off], s_cand[i].mac, 6);
        p[off + 6] = (uint8_t)s_cand[i].link;
        off += 7;
    }
    siot_safr_send(SAFR_BCAST_MAC, SAFR_MSG_TOPOLOGY, siot_safr_next_msg_id(), 0, p, off);
}

/* §12.3: probe for a parent; true when bound afterwards. */
static bool discover(void)
{
    s_rtc.wakes_since_probe = 0;
    const uint8_t n = probe(SAFR_PROBE_PARENT, 1, 0, SIOT_LEAF_PROBE_LISTEN_MS);
    s_rtc.heard_any = n > 0; /* nodes around (online or not) → probe every wake (§12.3) */
    /* Only a unit with a path to the board is a parent: LAYER 0xFF answers are
     * "here, but no board yet" — counted, listed in TOPOLOGY, never bound. */
    siot_leaf_candidate_t usable[SIOT_LEAF_CANDIDATES_MAX];
    size_t nu = 0;
    for (uint8_t i = 0; i < n; i++) if (s_cand[i].layer != 0xFF) usable[nu++] = s_cand[i];
    const int best = siot_leaf_pick_parent(usable, nu);
    if (best >= 0) {
        bind_to(&usable[best]);
    } else if (CONFIG_SIOT_LEAF_BENCH_PARENT_MAC[0]) {
        siot_leaf_candidate_t c;
        memset(&c, 0, sizeof(c));
        if (siot_mac_from_str(CONFIG_SIOT_LEAF_BENCH_PARENT_MAC, c.mac)) {
            memcpy(c.peer, c.mac, 6);
            c.layer = 0xFF;
            c.link = (int8_t)SAFR_NA_RSSI;
            ESP_LOGW(TAG, "no offer: binding to the bench parent %s", CONFIG_SIOT_LEAF_BENCH_PARENT_MAC);
            bind_to(&c);
        }
    }
    if (s_rtc.bind != BIND_BOUND) {
        s_rtc.bind = BIND_COMM_FAULT;
        ESP_LOGW(TAG, "no parent %s → COMM_FAULT (chirp)", n ? "with a path to the board (nodes heard, board not there yet)" : "in reach");
        return false;
    }
    /* TOPOLOGY first: the first frame after a bind names the new parent, so
     * every receiver (board table, tablet map) re-homes the leaf on that
     * frame; the name follows. */
    emit_topology();
    if (!s_rtc.announced && emit_name_announce()) s_rtc.announced = true;
    return true;
}

/* ---- 5. heartbeat cycle ------------------------------------------------------ */

/* Sends one frame with F_ACK_REQ and waits ≤ wait_ms for the parent's ACK.
 * Returns true on the hop ACK (§12.6 custody). */
static bool send_acked(uint8_t msg_type, const uint8_t *payload, size_t len, uint32_t wait_ms, uint8_t extra_flags)
{
    s_ack_wanted = siot_safr_next_msg_id();
    s_ack_hop = s_ack_central = false;
    siot_safr_send(SAFR_BCAST_MAC, msg_type, s_ack_wanted, SAFR_F_ACK_REQ | extra_flags, payload, len);
    if (!s_last_tx_ok) { /* no MAC ACK: one retry (§12.2) */
        siot_safr_send(SAFR_BCAST_MAC, msg_type, s_ack_wanted, SAFR_F_ACK_REQ | extra_flags, payload, len);
        if (!s_last_tx_ok) return false;
    }
    const int64_t until = now_ms() + wait_ms;
    while (!s_ack_hop && now_ms() < until) pump((uint32_t)(until - now_ms()));
    return s_ack_hop;
}

void siot_leafcore_set_ota(const siot_leafcore_ota_t *hooks)
{
    if (hooks) s_ota = *hooks;
    else memset(&s_ota, 0, sizeof(s_ota));
}

bool siot_leafcore_send_acked(uint8_t msg_type, const uint8_t *payload, size_t len, uint32_t wait_ms)
{
    return s_transport_up && send_acked(msg_type, payload, len, wait_ms, 0);
}

void siot_leafcore_send(uint8_t msg_type, const uint8_t *payload, size_t len)
{
    if (!s_transport_up) return;
    siot_safr_send(SAFR_BCAST_MAC, msg_type, siot_safr_next_msg_id(), 0, payload, len);
}

static void build_heartbeat(uint8_t p[20])
{
    siot_sensor_reading_t r;
    siot_sensor_read(&r);
    siot_put_u32(&p[0], epoch_now());
    siot_put_u32(&p[4], (uint32_t)(now_ms() / 1000));
    p[8] = SAFR_PWR_ON_BATTERY;
    p[9] = siot_sensor_battery_pct();
    siot_put_u16(&p[10], (uint16_t)(r.valid ? r.temp_x10 : SAFR_NA_I16));
    p[12] = (uint8_t)s_rtc.parent_link;
    memcpy(&p[13], s_rtc.parent_mac, 6);
    p[19] = leaf_level();
}

static void drain_outbox(void)
{
    uint8_t ev[17];
    bool changed = false;
    while (siot_leaf_outbox_peek(&s_rtc.outbox, ev)) {
        ESP_LOGI(TAG, "outbox: delivering type %u code %u dev_seq %u (%u left)", ev[0], ev[1],
                 siot_get_u16(&ev[15]), siot_leaf_outbox_count(&s_rtc.outbox));
        if (!send_acked(SAFR_MSG_EVENT, ev, sizeof(ev), SIOT_LEAF_ACK_WAIT_MS, 0)) break;
        siot_leaf_outbox_pop(&s_rtc.outbox);
        changed = true;
        if (siot_leaf_budget_left_ms(now_ms(), SIOT_LEAF_WAKE_BUDGET_MS) == 0) break;
    }
    if (changed) outbox_save();
}

/* An image was installed on this wake: the next one starts in INSTALL_WAKE_MS. */
static bool s_installed;

/* One timer wake while bound. Returns true when the parent answered. */
static bool heartbeat_cycle(void)
{
    drain_outbox();
    uint8_t p[20];
    build_heartbeat(p);
    s_mailbox_left = 0;
    const bool ok = send_acked(SAFR_MSG_HEARTBEAT, p, sizeof(p), SIOT_LEAF_ACK_WAIT_MS, 0);
    if (!ok) {
        s_rtc.misses++;
        ESP_LOGW(TAG, "heartbeat: no parent ACK (miss %u)", s_rtc.misses);
        return false;
    }
    s_rtc.misses = 0;
    /* §12.5 drain: the parent sends the queued frames right after its ACK. */
    const int64_t drain_start = now_ms();
    while (s_mailbox_left > 0) {
        const uint32_t left = siot_leaf_budget_left_ms(now_ms(), SIOT_LEAF_WAKE_BUDGET_MS);
        if (left == 0) { ESP_LOGW(TAG, "mailbox: budget spent, %d frame(s) wait for the next wake", s_mailbox_left); break; }
        const int before = s_mailbox_left;
        pump(left > 100 ? 100 : left);
        if (s_mailbox_left == before) { ESP_LOGW(TAG, "mailbox: parent went quiet, %d frame(s) wait for the next wake", s_mailbox_left); break; }
    }
    if (s_mailbox_total) ESP_LOGW(TAG, "mailbox: drained %d of %d in %lld ms", s_mailbox_total - s_mailbox_left, s_mailbox_total,
                                  (long long)(now_ms() - drain_start));
    else ESP_LOGI(TAG, "mailbox: empty (nothing waiting for me)");
    return true;
}

/* ---- 6. verdicts, setup, sleep ------------------------------------------------ */

static void led_off(void) { siot_ui_led_set(SIOT_LED_OFF, 0); }

static void wait_led(uint32_t ms)
{
    const int64_t until = now_ms() + ms;
    while (now_ms() < until) pump(50);
}

static void walk_test(void)
{
    ESP_LOGW(TAG, "walk test (MANUAL_TEST, waiting for the central's ACK)");
    uint8_t ev[17];
    build_event(ev, SAFR_EVT_ALERT, SAFR_EC_MANUAL_TEST);
    const bool hop = send_acked(SAFR_MSG_EVENT, ev, sizeof(ev), SIOT_LEAF_ACK_WAIT_MS, 0);
    if (!hop) {
        ESP_LOGW(TAG, "walk test: parent did not acknowledge → outbox");
        if (siot_leaf_outbox_push(&s_rtc.outbox, ev)) ESP_LOGW(TAG, "outbox full: oldest non-alarm dropped");
        outbox_save();
        s_rtc.misses++;
    }
    const int64_t until = now_ms() + SIOT_LEAF_WALKTEST_ACK_MS;
    while (!s_ack_central && now_ms() < until) pump((uint32_t)(until - now_ms()));
    if (s_ack_central) {
        ESP_LOGW(TAG, "walk test: CYAN — the central confirmed");
        const siot_evt_ack_t ack = {.msg_id = s_ack_wanted, .status = SAFR_ACK_OK};
        siot_evbus_post(SIOT_EVT_ACK_RECEIVED, &ack, sizeof(ack)); /* siot_ui_led: the one cyan rule */
        wait_led(2 * SIOT_LED_MSG_MS + 100); /* the cyan queues behind the blue "sent" pulse */
    } else {
        ESP_LOGW(TAG, "walk test: no ACK from the central within %d ms → RED", SIOT_LEAF_WALKTEST_ACK_MS);
        siot_ui_led_pulse(SIOT_LED_RED_SOLID, SIOT_LED_SURVEY_ANSWER_MS, false);
        wait_led(SIOT_LED_SURVEY_ANSWER_MS + 100);
    }
}

static void survey(void)
{
    ESP_LOGW(TAG, "survey (no path to the board)");
    const int64_t start = now_ms();
    const uint8_t n = probe(SAFR_PROBE_SURVEY, SURVEY_COPIES, SURVEY_SPACING_MS, SURVEY_WINDOW_MS);
    int8_t best = (int8_t)SAFR_NA_RSSI;
    for (uint8_t i = 0; i < n; i++) if (i == 0 || s_cand[i].link > best) best = s_cand[i].link;
    if (n == 0) ESP_LOGW(TAG, "survey: nobody answered → RED");
    else ESP_LOGW(TAG, "survey: %u unit(s) answered, best link %d dBm", n, best);
    const siot_evt_survey_t ev = {.count = n, .best_rssi = best};
    siot_evbus_post(SIOT_EVT_SURVEY_RESULT, &ev, sizeof(ev)); /* siot_ui_led: one red blink when nobody */
    /* Stay awake until the last blink (and its gap) has played. */
    const int64_t blinks_ms = n ? (int64_t)n * (SIOT_LED_SURVEY_ANSWER_MS + SIOT_LED_SURVEY_ANSWER_MS / 2)
                                : SIOT_LED_SURVEY_ANSWER_MS;
    const int64_t left = blinks_ms + 200 - (now_ms() - start);
    wait_led(left > 300 ? (uint32_t)left : 300);
}

/* What a press does once the button is released, and what the leaf does by
 * itself on its first wake with a code (§12.8) — the same LEDs as a node's
 * TEST: walk test = blue sent, cyan confirmed; survey = one blink per unit. */
static void test_or_survey(void)
{
    /* Unbound or NO_PATH: try to (re)bind first (200 ms) — the installer's
     * press is the natural moment to join once the board is up. A survey
     * sends nothing acked, so without this a NO_PATH leaf would keep
     * surveying until its next heartbeat ACK, long after the board is back.
     * A failed probe keeps the old parent, as on a timer wake. */
    if (s_rtc.bind != BIND_BOUND) discover();
    else if (s_rtc.no_path && !discover()) s_rtc.bind = BIND_BOUND;
    if (s_rtc.bind == BIND_BOUND && !s_rtc.no_path) walk_test();
    else survey();
}

static void verdict_after_provisioning(void)
{
    ESP_LOGW(TAG, "post-provisioning verdict (≤ %d s)", SIOT_LEAF_VERDICT_WINDOW_MS / 1000);
    s_led_allowed = true;
    siot_ui_led_pulse(SIOT_LED_BLUE_SOLID, SIOT_LED_TICK_MS, false); /* as on a press */
    test_or_survey();
    s_led_allowed = false;
    s_rtc.verdict_pending = false;
}

static void button_wake(void)
{
    s_led_allowed = true;
    siot_ui_led_pulse(SIOT_LED_BLUE_SOLID, SIOT_LED_TICK_MS, false); /* "heard you, sending" */
    /* Still held: let siot_ui_button's 5 s hold reach the factory reset. */
    if (s_button_pin != SIOT_PIN_NONE && siot_hal_gpio_read(s_button_pin) == 0) {
        const int64_t until = now_ms() + HOLD_CHECK_MS;
        while (siot_hal_gpio_read(s_button_pin) == 0 && now_ms() < until) pump(50);
    }
    test_or_survey();
    s_led_allowed = false;
}

/* Setup window (§12.9): activity = an HTTP request on the setup network or a
 * phone joining. Nothing for SETUP_WINDOW_S → sleep. A phone that just stays
 * associated (phones reconnect on their own) is NOT activity, and SETUP_MAX_S
 * caps the whole thing from boot whatever happens: never waste battery. */
static volatile int64_t s_ap_last_join_ms;

static void on_wifi_ap_event(void *arg, esp_event_base_t base, int32_t id, void *data)
{
    (void)arg; (void)base;
    char m[SIOT_MAC_STR_LEN];
    if (id == WIFI_EVENT_AP_STACONNECTED) {
        const wifi_event_ap_staconnected_t *e = data;
        s_ap_last_join_ms = now_ms();
        ESP_LOGW(TAG, "setup: phone %s joined (aid %u) — %d s without a request until sleep",
                 siot_mac_to_str(e->mac, m), e->aid, CONFIG_SIOT_LEAF_SETUP_WINDOW_S);
    } else if (id == WIFI_EVENT_AP_STADISCONNECTED) {
        const wifi_event_ap_stadisconnected_t *e = data;
        /* reason (esp_wifi_types_generic.h wifi_err_reason_t): 8 = the phone left on
         * its own, 15 = 4-way handshake timeout = WRONG PASSWORD (pop ≠ QR),
         * 2 / 4 = auth / assoc expired (phone went silent). */
        ESP_LOGW(TAG, "setup: phone %s left, reason %u%s", siot_mac_to_str(e->mac, m), e->reason,
                 e->reason == 15 ? " (4-way handshake timeout: the phone used a password that is not this unit's pop)"
                 : e->reason == 8 ? " (the phone left by itself)" : "");
    }
}

static void setup_mode(void)
{
    ESP_LOGW(TAG, "no code: setup network up; sleeps after %d s without a request (cap %d s from boot, §12.9)",
             CONFIG_SIOT_LEAF_SETUP_WINDOW_S, CONFIG_SIOT_LEAF_SETUP_MAX_S);
    const siot_evt_state_t ev = {.prev = SIOT_STATE_SETUP, .next = SIOT_STATE_SETUP};
    siot_evbus_post(SIOT_EVT_STATE_CHANGED, &ev, sizeof(ev)); /* LED: white blink */
    esp_event_handler_register(WIFI_EVENT, WIFI_EVENT_AP_STACONNECTED, on_wifi_ap_event, NULL);
    esp_event_handler_register(WIFI_EVENT, WIFI_EVENT_AP_STADISCONNECTED, on_wifi_ap_event, NULL);
    ESP_LOGW(TAG, "setup: starting the setup network (SoftAP + HTTP)...");
    const esp_err_t perr = siot_provisioning_start(false);
    ESP_LOGW(TAG, "setup: provisioning start returned %s", esp_err_to_name(perr));
    /* /provision → on_stored → esp_restart(): we only watch the window. */
    const int64_t window = (int64_t)CONFIG_SIOT_LEAF_SETUP_WINDOW_S * 1000;
    const int64_t cap    = (int64_t)CONFIG_SIOT_LEAF_SETUP_MAX_S * 1000;
    const int64_t boot   = now_ms();
    int64_t next_alive = boot + 10000;
    for (;;) {
        vTaskDelay(pdMS_TO_TICKS(500));
        const int64_t t = now_ms();
        if (t >= next_alive) { /* one line every 10 s: proves the task and the console are alive */
            ESP_LOGI(TAG, "setup: alive %llds, last request %llds ago", (long long)((t - boot) / 1000),
                     siot_provisioning_last_activity_ms() ? (long long)((t - siot_provisioning_last_activity_ms()) / 1000) : -1LL);
            next_alive = t + 10000;
        }
        const int64_t req = siot_provisioning_last_activity_ms();
        int64_t last = boot;
        if (req > last) last = req;
        if (s_ap_last_join_ms > last) last = s_ap_last_join_ms;
        if (t - last >= window) { ESP_LOGW(TAG, "setup: %d s without activity → sleep", CONFIG_SIOT_LEAF_SETUP_WINDOW_S); break; }
        if (t - boot >= cap)    { ESP_LOGW(TAG, "setup: %d s cap reached → sleep", CONFIG_SIOT_LEAF_SETUP_MAX_S); break; }
    }
    ESP_LOGW(TAG, "setup over: sleeping until the button is pressed");
}

static void leaf_sleep(uint32_t ms, bool timer)
{
    led_off();
    if (s_code != NULL) s_rtc.msg_id = siot_safr_last_msg_id();
    const int64_t awake = now_ms();
    ESP_LOGW(TAG, "wake #%lu done: awake_ms=%lld, next %s", (unsigned long)s_rtc.wake_count, (long long)awake,
             timer ? "timer" : "button only");
    wifi_down();
    esp_wifi_stop(); /* setup mode: the AP belongs to siot_provisioning — never sleep with the radio up */
    vTaskDelay(pdMS_TO_TICKS(20)); /* let the UART finish the line */
#if CONFIG_SIOT_LEAF_SLEEP_DEEP || CONFIG_SIOT_LEAF_SLEEP_LIGHT
    if (s_button_pin != SIOT_PIN_NONE && rtc_gpio_is_valid_gpio((gpio_num_t)s_button_pin)) {
        rtc_gpio_pullup_en((gpio_num_t)s_button_pin);
        rtc_gpio_pulldown_dis((gpio_num_t)s_button_pin);
        /* The devkit has no external pull-up: keep RTC_PERIPH on so the
         * internal one holds (esp_sleep.h). The PCB's pull-up lets this go. */
        esp_sleep_pd_config(ESP_PD_DOMAIN_RTC_PERIPH, ESP_PD_OPTION_ON);
        esp_sleep_enable_ext1_wakeup_io(1ULL << s_button_pin, ESP_EXT1_WAKEUP_ANY_LOW);
    }
    if (timer) esp_sleep_enable_timer_wakeup((uint64_t)ms * 1000ULL);
#endif
#if CONFIG_SIOT_LEAF_SLEEP_DEEP
    esp_deep_sleep_start();
#elif CONFIG_SIOT_LEAF_SLEEP_LIGHT
    esp_light_sleep_start();
    s_sim_cause = esp_sleep_get_wakeup_cause();
#else
    s_tap_flag = false;
    const int64_t until = timer ? now_ms() + ms : INT64_MAX;
    while (now_ms() < until && !s_tap_flag) vTaskDelay(pdMS_TO_TICKS(50));
    s_sim_cause = s_tap_flag ? ESP_SLEEP_WAKEUP_EXT1 : ESP_SLEEP_WAKEUP_TIMER;
#endif
}

static void on_tap(siot_evt_id_t id, const void *data, void *ctx)
{
    (void)id; (void)data; (void)ctx;
    s_tap_flag = true;
}

static void one_wake(esp_sleep_wakeup_cause_t cause)
{
    const int64_t wake_started_ms = now_ms();
    s_rtc.wake_count++;
    s_rtc.wakes_since_probe++;
    ESP_LOGW(TAG, "wake #%lu cause=%s bind=%s misses=%u outbox=%u ch=%u", (unsigned long)s_rtc.wake_count,
             cause_name(cause), s_rtc.bind == BIND_BOUND ? "bound" : s_rtc.bind == BIND_COMM_FAULT ? "COMM_FAULT" : "none",
             s_rtc.misses, siot_leaf_outbox_count(&s_rtc.outbox), s_rtc.channel);

    if (wifi_up(s_rtc.channel) != ESP_OK) {
        ESP_LOGE(TAG, "radio failed to start; sleeping");
        return;
    }
    siot_safr_set_level(leaf_level());

    /* §13.5: a new image's first wake, or a result the board still has to
     * hear — this wake needs a parent whatever the state says. */
    const bool selftest = s_ota.selftest_pending && s_ota.selftest_pending();
    const bool ota_wants_parent = selftest || (s_ota.report_due && s_ota.report_due());

    if (s_rtc.verdict_pending) {
        if (!ota_wants_parent) { verdict_after_provisioning(); return; }
        s_rtc.verdict_pending = false; /* a unit that just changed firmware is not freshly provisioned */
    }
    if (cause == ESP_SLEEP_WAKEUP_EXT1) { button_wake(); return; }

    bool heard = false;
    if (s_rtc.bind == BIND_BOUND) {
        if (s_rtc.wakes_since_probe >= SIOT_LEAF_REPROBE_WAKES || s_rtc.no_path) {
            /* §12.3: daily, or the wake after a NO_PATH ACK. discover() only
             * touches the parent fields on success, so a silent probe keeps
             * the old parent — it is still the best relay when the board returns. */
            ESP_LOGI(TAG, "%s re-probe", s_rtc.no_path ? "NO_PATH" : "periodic");
            if (!discover()) s_rtc.bind = BIND_BOUND;
        }
        heard = heartbeat_cycle();
        /* a new image gets this one wake to prove it can talk — worth two more
         * heartbeats before it gives itself up */
        for (int i = 0; selftest && !heard && i < 2; i++) {
            vTaskDelay(pdMS_TO_TICKS(300));
            heard = heartbeat_cycle();
        }
        if (!heard && siot_leaf_probe_after_misses(s_rtc.misses)) {
            ESP_LOGW(TAG, "%u misses → looking for another parent", s_rtc.misses);
            if (discover() && selftest) heard = heartbeat_cycle();
        }
    } else {
        if (ota_wants_parent || siot_leaf_probe_due_unbound(s_rtc.wakes_since_probe, s_rtc.heard_any)) {
            if (discover()) heard = heartbeat_cycle();
        }
        if (s_rtc.bind != BIND_BOUND) ESP_LOGW(TAG, "COMM_FAULT: chirp (no sounder on the devkit)");
    }

    if (selftest && s_ota.selftest_verdict) {
        if (!heard) rtc_mirror_save(); /* the rollback restarts into the other image: hand it our state */
        s_ota.selftest_verdict(heard);  /* a rollback does not return */
    }
    if (heard) {
        if (s_ota.report_if_due) s_ota.report_if_due();
        if (!s_rtc.announced && emit_name_announce()) s_rtc.announced = true; /* first wake of another image */
        if (s_ack_last.has_offer && s_ota.on_offer) {
            const bool installed = s_ota.on_offer(s_ack_last.offer_msg_id, &s_ack_last.offer,
                                                  cause != ESP_SLEEP_WAKEUP_TIMER && cause != ESP_SLEEP_WAKEUP_UNDEFINED,
                                                  s_rtc.parent_mac, wake_started_ms);
            s_ack_last.has_offer = false;
            if (installed) {
                rtc_mirror_save(); /* the next wake boots the new image: hand it our state */
                s_installed = true; /* …and comes in 1 s, not at the next heartbeat (§13.5) */
                return;            /* sleep now */
            }
        }
    }
    /* IDENTIFY from the mailbox keeps us awake for its duration. */
    while (now_ms() < s_stay_awake_until_ms) pump(100);
}

void siot_leafcore_run(bool has_code)
{
    s_rx_queue = xQueueCreate(RX_QUEUE_LEN, sizeof(rx_item_t));
    s_send_sem = xSemaphoreCreateBinary();
    s_button_pin = siot_board_def()->button;
    memcpy(s_my_mac, siot_identity_get()->mac, 6);
    siot_evbus_subscribe(SIOT_EVT_BUTTON_TAP, on_tap, NULL, NULL);

    if (!has_code) {
        setup_mode();
        for (;;) leaf_sleep(0, false); /* NONE/LIGHT: comes back on a tap → the app reboots into setup again */
    }

    s_code = siot_config_code();
    /* siot_ui_led starts in SETUP (white blink) and only a state event moves
     * it; a leaf never posted one, so the end of a survey (which re-applies
     * the base pattern) flashed the setup white — read as a cyan
     * "confirmation" with the board off. A provisioned leaf rests dark:
     * ONLINE at level 0 is SIOT_LED_OFF; only the §12.8 flows light it. */
    const siot_evt_state_t running = {.prev = SIOT_STATE_SETUP, .next = SIOT_STATE_ONLINE};
    siot_evbus_post(SIOT_EVT_STATE_CHANGED, &running, sizeof(running));
    if (s_rtc.magic != RTC_MAGIC || s_rtc.system_id != s_code->system_id) {
        if (!rtc_mirror_take()) {
            rtc_reset();
            ESP_LOGW(TAG, "fresh state (power-on, or first boot with this code)");
        }
    } else {
        rtc_mirror_take(); /* the same layout after all: just drop the mirror */
    }
    if (s_rtc.channel == 0) s_rtc.channel = s_code->channel;
    /* A wake is a boot and siot_safr restarts at MSG_ID 0: continue from the
     * last wake, or every receiver's 30 s (SRC_MAC, MSG_ID) window takes this
     * wake's frames for repeats of the last one's — a second TEST press within
     * 30 s lit no node, and a stale ACK could pass for this wake's. */
    siot_safr_set_last_msg_id(s_rtc.msg_id);
    siot_safr_set_tx(tx_sink, NULL);
    siot_safr_register(SAFR_MSG_ACK, on_ack, NULL);
    siot_safr_register(SAFR_MSG_PARENT_OFFER, on_offer, NULL);
    siot_safr_register(SAFR_MSG_COMMAND, on_command, NULL);
    siot_sensor_init();
    ESP_LOGI(TAG, "leaf ready: system_id=0x%04X name=\"%s\" ch=%u hb=%us sensors=%s", s_code->system_id,
             s_code->name, s_rtc.channel, CONFIG_SIOT_LEAF_HB_INTERVAL_S, siot_sensor_backend());

    esp_sleep_wakeup_cause_t cause = esp_sleep_get_wakeup_cause();
    for (;;) {
        one_wake(cause);
        const int64_t awake = now_ms();
        const uint32_t left = s_installed                         ? INSTALL_WAKE_MS
                            : awake >= (int64_t)HB_INTERVAL_MS ? 1000u
                                                                : (uint32_t)(HB_INTERVAL_MS - awake);
        s_installed = false;
        leaf_sleep(left, true);
        cause = s_sim_cause; /* LIGHT / NONE only; DEEP never gets here */
    }
}
