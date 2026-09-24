#include "siot_survey.h"

#include <string.h>

#include "esp_log.h"
#include "esp_now.h"
#include "esp_timer.h"
#include "esp_wifi.h"
#include "sdkconfig.h"

#if CONFIG_MESH_LITE_ENABLE
#include "esp_mesh_lite.h"
#endif

#include "siot_evbus.h"
#include "siot_safr.h"
#include "siot_util.h"

static const char *TAG = "siot_survey";

/* One-byte type in front of every ESP-NOW payload: Mesh-Lite's dispatcher
 * (esp_mesh_lite_espnow.c) routes on it and strips it; the board does the
 * same by hand. Inside Mesh-Lite's reserved range, above what it uses. */
#define SIOT_ESPNOW_TYPE 0xD2

static uint8_t s_layer = 0xFF;
static bool    s_online;
static bool    s_ready;

/* One probe at a time: the rx callback fills these, the timer reports.
 * The probe is repeated (same MSG_ID, fresh MSG_CTR) because, with no board on
 * site, every unit scans all channels for the board's Wi-Fi for ~3 s every
 * ~13 s: while scanning it neither hears nor sends on the installation
 * channel. Four copies 1.2 s apart span 3.6 s, longer than one scan on
 * either side, so at least one copy always lands (bench, 2026-09-24: three
 * copies over 1.2 s still lost whole probes). Answers are counted per MAC. */
#define PROBE_REPEATS    4
#define PROBE_SPACING_MS 1200
#define MAX_ANSWERERS   8
static volatile bool    s_probing;
static volatile uint8_t s_offers;
static volatile int8_t  s_best_rssi;
static uint8_t          s_answerers[MAX_ANSWERERS][6];
static uint16_t         s_probe_msg_id;
static uint8_t          s_probe_sent;
static esp_timer_handle_t s_collect_timer;
static esp_timer_handle_t s_repeat_timer;

/* RSSI of the frame being dispatched (recv cb → handler, same task). */
static int8_t s_rx_rssi;

static esp_err_t ensure_peer(const uint8_t mac[6])
{
    if (esp_now_is_peer_exist(mac)) return ESP_OK;
    esp_now_peer_info_t peer;
    memset(&peer, 0, sizeof(peer));
    memcpy(peer.peer_addr, mac, 6);
    peer.channel = 0;          /* the interface's current channel */
    peer.ifidx = WIFI_IF_AP;   /* the AP sits on the installation channel on both images */
    peer.encrypt = false;      /* SAFR already authenticates and encrypts */
    const esp_err_t err = esp_now_add_peer(&peer);
    return err == ESP_ERR_ESPNOW_EXIST ? ESP_OK : err;
}

/* ---- transport ------------------------------------------------------------ */

static void deliver(const esp_now_recv_info_t *info, const uint8_t *frame, int len)
{
    if (len < SAFR_MIN_FRAME || frame[0] != SAFR_SOF) return;
    const uint8_t type = frame[4];
    if (type != SAFR_MSG_PARENT_PROBE && type != SAFR_MSG_PARENT_OFFER) return; /* not ours */
    s_rx_rssi = (info && info->rx_ctrl) ? (int8_t)info->rx_ctrl->rssi : (int8_t)SAFR_NA_RSSI;
    siot_safr_rx(frame, (size_t)len);
}

#if CONFIG_MESH_LITE_ENABLE
/* Node: Mesh-Lite already stripped the type byte. */
static esp_err_t on_mesh_lite_rx(const esp_now_recv_info_t *info, const uint8_t *data, int len)
{
    deliver(info, data, len);
    return ESP_OK;
}

static esp_err_t transport_init(void)
{
    /* esp_now_init + the one recv callback belong to Mesh-Lite (User Guide
     * §ESP-NOW); we only register our type. */
    return esp_mesh_lite_espnow_recv_cb_register((esp_mesh_lite_espnow_data_type_t)SIOT_ESPNOW_TYPE,
                                                 on_mesh_lite_rx);
}

static esp_err_t transport_send(const uint8_t dst[6], const uint8_t *frame, size_t len)
{
    uint8_t dst_copy[6];
    memcpy(dst_copy, dst, 6);
    return esp_mesh_lite_espnow_send(SIOT_ESPNOW_TYPE, dst_copy, frame, len);
}
#else
/* Board: raw ESP-NOW, same one-byte type prefix. */
static void on_espnow_rx(const esp_now_recv_info_t *info, const uint8_t *data, int len)
{
    if (len < 1 || data[0] != SIOT_ESPNOW_TYPE) return;
    deliver(info, data + 1, len - 1);
}

static esp_err_t transport_init(void)
{
    esp_err_t err = esp_now_init();
    if (err != ESP_OK && err != ESP_ERR_ESPNOW_EXIST) return err;
    return esp_now_register_recv_cb(on_espnow_rx);
}

static esp_err_t transport_send(const uint8_t dst[6], const uint8_t *frame, size_t len)
{
    if (len + 1 > ESP_NOW_MAX_DATA_LEN) return ESP_ERR_INVALID_SIZE;
    uint8_t buf[ESP_NOW_MAX_DATA_LEN];
    buf[0] = SIOT_ESPNOW_TYPE;
    memcpy(&buf[1], frame, len);
    return esp_now_send(dst, buf, len + 1);
}
#endif

bool siot_survey_tx(const uint8_t *frame, size_t len, const uint8_t dst_mac[6])
{
    if (len < 5) return false;
    const uint8_t type = frame[4];
    if (type != SAFR_MSG_PARENT_PROBE && type != SAFR_MSG_PARENT_OFFER) return false;
    if (!s_ready) return true;
    esp_err_t err = ensure_peer(dst_mac);
    if (err == ESP_OK) err = transport_send(dst_mac, frame, len);
    if (err != ESP_OK) ESP_LOGW(TAG, "espnow send type 0x%02X: %s", type, esp_err_to_name(err));
    return true;
}

/* ---- responder --------------------------------------------------------- */

static void on_probe(const siot_safr_frame_t *f, const uint8_t *raw, size_t raw_len, bool dup, void *ctx)
{
    (void)raw; (void)raw_len; (void)ctx; /* every copy is answered: the prober may have missed the first offer */
    if (f->payload_len < 1) return;
    const uint8_t purpose = f->payload[0];
    if (purpose == SAFR_PROBE_PARENT && !s_online) return; /* leafs want an ONLINE AC parent */
    if (purpose != SAFR_PROBE_PARENT && purpose != SAFR_PROBE_SURVEY) return;

    const uint8_t offer[3] = {purpose, (uint8_t)s_rx_rssi, s_layer};
    char src[SIOT_MAC_STR_LEN];
    ESP_LOGI(TAG, "probe msg_id %u (purpose %u%s) from %s at %d dBm -> offer", f->msg_id, purpose,
             dup ? ", repeat" : "", siot_mac_to_str(f->src_mac, src), s_rx_rssi);
    siot_safr_send(f->src_mac, SAFR_MSG_PARENT_OFFER, siot_safr_next_msg_id(), 0, offer, sizeof(offer));

    if (purpose == SAFR_PROBE_SURVEY && !dup) { /* "I heard you, this well": 1 s in the link colour */
        const siot_evt_rssi_t heard = {.rssi = s_rx_rssi};
        siot_evbus_post(SIOT_EVT_SURVEY_HEARD, &heard, sizeof(heard));
    }
}

/* ---- prober ------------------------------------------------------------ */

static void on_offer(const siot_safr_frame_t *f, const uint8_t *raw, size_t raw_len, bool dup, void *ctx)
{
    (void)raw; (void)raw_len; (void)ctx; (void)dup;
    if (!s_probing || f->payload_len < 3) return;
    const int8_t rssi_seen = (int8_t)f->payload[1];
    /* The weaker direction of the pair is the honest number. */
    const int8_t rssi = rssi_seen < s_rx_rssi ? rssi_seen : s_rx_rssi;
    char src[SIOT_MAC_STR_LEN];
    ESP_LOGI(TAG, "offer from %s: they saw %d dBm, we see %d dBm, layer %u",
             siot_mac_to_str(f->src_mac, src), rssi_seen, s_rx_rssi, f->payload[2]);
    if (s_offers == 0 || rssi > s_best_rssi) s_best_rssi = rssi;
    for (uint8_t i = 0; i < s_offers && i < MAX_ANSWERERS; i++) {
        if (siot_mac_eq(s_answerers[i], f->src_mac)) return; /* same unit answering a repeated probe */
    }
    if (s_offers < MAX_ANSWERERS) memcpy(s_answerers[s_offers], f->src_mac, 6);
    if (s_offers < 0xFF) s_offers++;
    const siot_evt_rssi_t ans = {.rssi = rssi}; /* one blink per unit, in its link colour */
    siot_evbus_post(SIOT_EVT_SURVEY_ANSWER, &ans, sizeof(ans));
}

static esp_err_t send_probe(void)
{
    const uint8_t probe[1] = {SAFR_PROBE_SURVEY};
    return siot_safr_send(SAFR_BCAST_MAC, SAFR_MSG_PARENT_PROBE, s_probe_msg_id, 0, probe, sizeof(probe));
}

static void repeat_probe(void *arg)
{
    (void)arg;
    if (!s_probing || s_probe_sent >= PROBE_REPEATS) return;
    s_probe_sent++;
    const esp_err_t err = send_probe();
    ESP_LOGI(TAG, "probe copy %u/%u: %s", s_probe_sent, PROBE_REPEATS, esp_err_to_name(err));
    if (s_probe_sent < PROBE_REPEATS) esp_timer_start_once(s_repeat_timer, (uint64_t)PROBE_SPACING_MS * 1000);
}

static void collect_done(void *arg)
{
    (void)arg;
    s_probing = false;
    const siot_evt_survey_t ev = {.count = s_offers, .best_rssi = s_best_rssi};
    if (ev.count == 0) ESP_LOGW(TAG, "survey: no unit answered -> RED");
    else ESP_LOGW(TAG, "survey: %u unit(s) answered, best %d dBm -> %s", ev.count, ev.best_rssi,
                  ev.best_rssi >= -75 ? "GREEN" : "YELLOW");
    siot_evbus_post(SIOT_EVT_SURVEY_RESULT, &ev, sizeof(ev));
}

esp_err_t siot_survey_probe(void)
{
    if (!s_ready) return ESP_ERR_INVALID_STATE;
    if (s_probing) {
        /* A press inside the window restarts the survey: the blinks end long
         * before the window does, so "ignored" reads as "broken" (bench 2026-09-24). */
        ESP_LOGW(TAG, "survey restarted by a new press (previous: %u answer(s))", s_offers);
        esp_timer_stop(s_repeat_timer);
        esp_timer_stop(s_collect_timer);
        s_probing = false;
    }
    s_offers = 0;
    s_best_rssi = -128;
    s_probing = true;
    s_probe_msg_id = siot_safr_next_msg_id();
    s_probe_sent = 1;
    const esp_err_t err = send_probe();
    if (err != ESP_OK) {
        s_probing = false;
        return err;
    }
    ESP_LOGW(TAG, "survey msg_id %u: probe copy 1/%d sent (x%d over %d ms); collecting for %d ms",
             s_probe_msg_id, PROBE_REPEATS, PROBE_REPEATS, PROBE_SPACING_MS * (PROBE_REPEATS - 1),
             SIOT_SURVEY_COLLECT_MS);
    esp_timer_start_once(s_repeat_timer, (uint64_t)PROBE_SPACING_MS * 1000);
    return esp_timer_start_once(s_collect_timer, (uint64_t)SIOT_SURVEY_COLLECT_MS * 1000);
}

esp_err_t siot_survey_init(uint8_t layer)
{
    s_layer = layer;
    esp_err_t err = transport_init();
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "espnow transport: %s", esp_err_to_name(err));
        return err;
    }
    if ((err = ensure_peer(SAFR_BCAST_MAC)) != ESP_OK) {
        ESP_LOGE(TAG, "broadcast peer: %s", esp_err_to_name(err));
        return err;
    }
    if ((err = siot_safr_register(SAFR_MSG_PARENT_PROBE, on_probe, NULL)) != ESP_OK) return err;
    if ((err = siot_safr_register(SAFR_MSG_PARENT_OFFER, on_offer, NULL)) != ESP_OK) return err;
    const esp_timer_create_args_t targs = {.callback = collect_done, .name = "survey"};
    if ((err = esp_timer_create(&targs, &s_collect_timer)) != ESP_OK) return err;
    const esp_timer_create_args_t rargs = {.callback = repeat_probe, .name = "survey_rep"};
    if ((err = esp_timer_create(&rargs, &s_repeat_timer)) != ESP_OK) return err;
    s_ready = true;
    ESP_LOGI(TAG, "ESP-NOW survey ready (%s, layer %u)",
#if CONFIG_MESH_LITE_ENABLE
             "via Mesh-Lite",
#else
             "raw esp_now",
#endif
             layer);
    return ESP_OK;
}

void siot_survey_set_layer(uint8_t layer) { s_layer = layer; }
void siot_survey_set_online(bool online) { s_online = online; }
