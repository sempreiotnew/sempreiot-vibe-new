/* siot_leafmgr — see the header. Layout:
 *   1. state + ESP-NOW send with MAC-ACK status
 *   2. uplink from a leaf (§12.4 ACK, §12.6 custody, forward)
 *   3. downlink to a leaf (§12.5 mailbox / immediate delivery)
 *   4. task: custody retries, expiry             5. init
 * Numbers come from siot_leaf_proto.h, never from here. */
#include "siot_leafmgr.h"

#include "sdkconfig.h"

/* Every image compiles every component under features/; the parent role is
 * only built into images that switch it on (features/README.md item 2). */
#if !CONFIG_SIOT_FEATURE_LEAFMGR
esp_err_t siot_leafmgr_init(void) { return ESP_ERR_NOT_SUPPORTED; }
#else

#include <string.h>

#include "esp_log.h"
#include "esp_now.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/semphr.h"
#include "freertos/task.h"
#include "sdkconfig.h"

#include "siot_config.h"
#include "siot_leaf_proto.h"
#include "siot_link.h"
#include "siot_netcore.h"
#include "siot_safr.h"
#include "siot_survey.h"
#include "siot_util.h"

static const char *TAG = "siot_leafmgr";

#define MAX_LEAVES       CONFIG_SIOT_LEAFMGR_MAX_LEAVES
#define AWAKE_WINDOW_MS  3000   /* heard this recently: probably still awake (walk test, alarm) → try at once */
#define LEAF_TTL_MS      (3 * SIOT_LEAF_HB_INTERVAL_S * 1000) /* §12.11 item 4 */
#define SEND_WAIT_MS     50
#define RXQ_LEN          8
#define TICK_MS          1000

/* ---- 1. state ---------------------------------------------------------------- */

typedef struct {
    bool     used;
    uint8_t  mac[6];   /* SAFR SRC_MAC */
    uint8_t  peer[6];  /* ESP-NOW address it sends from (unicast target) */
    int64_t  last_seen_ms;
    int8_t   rssi;
    uint8_t  battery;
    siot_leaf_rx_state_t rx;
    siot_leaf_mailbox_t  mailbox;
} leaf_t;

typedef struct {
    uint8_t src[6];
    int8_t  rssi;
    uint8_t len;
    uint8_t data[SAFR_MAX_FRAME];
} rx_item_t;

static leaf_t             s_leaves[MAX_LEAVES];
static siot_leaf_custody_t s_custody;
static SemaphoreHandle_t  s_lock;      /* recursive: the TX hook runs inside locked sections */
static QueueHandle_t      s_rxq;
static SemaphoreHandle_t  s_send_sem;
static volatile bool      s_send_ok;
static uint8_t            s_send_target[6];
static uint32_t           s_stat_rx, s_stat_foreign, s_stat_auth, s_stat_bad, s_stat_replay, s_stat_fwd;

static int64_t now_ms(void) { return esp_timer_get_time() / 1000; }
static void lock(void) { xSemaphoreTakeRecursive(s_lock, portMAX_DELAY); }
static void unlock(void) { xSemaphoreGiveRecursive(s_lock); }

static leaf_t *find_leaf(const uint8_t mac[6])
{
    for (int i = 0; i < MAX_LEAVES; i++) if (s_leaves[i].used && siot_mac_eq(s_leaves[i].mac, mac)) return &s_leaves[i];
    return NULL;
}

static leaf_t *find_or_add_leaf(const uint8_t mac[6], const uint8_t peer[6])
{
    leaf_t *l = find_leaf(mac);
    if (l) return l;
    leaf_t *victim = NULL;
    for (int i = 0; i < MAX_LEAVES; i++) {
        if (!s_leaves[i].used) { l = &s_leaves[i]; break; }
        if (victim == NULL || s_leaves[i].last_seen_ms < victim->last_seen_ms) victim = &s_leaves[i];
    }
    if (l == NULL) { l = victim; ESP_LOGW(TAG, "leaf table full: evicting the quietest"); }
    memset(l, 0, sizeof(*l));
    l->used = true;
    memcpy(l->mac, mac, 6);
    memcpy(l->peer, peer, 6);
    siot_leaf_mailbox_init(&l->mailbox);
    char m[SIOT_MAC_STR_LEN];
    ESP_LOGW(TAG, "new leaf %s", siot_mac_to_str(mac, m));
    return l;
}

static void on_espnow_sent(const esp_now_send_info_t *tx_info, esp_now_send_status_t status)
{
    if (tx_info && tx_info->des_addr && memcmp(tx_info->des_addr, s_send_target, 6) != 0) return; /* not ours */
    s_send_ok = status == ESP_NOW_SEND_SUCCESS;
    xSemaphoreGive(s_send_sem);
}

/* Unicast to a leaf: true = the 802.11 MAC ACK came back (it is awake and heard us). */
static bool espnow_send_wait(const uint8_t peer[6], const uint8_t *frame, size_t len)
{
    memcpy(s_send_target, peer, 6);
    xSemaphoreTake(s_send_sem, 0);
    s_send_ok = false;
    if (siot_survey_espnow_send(peer, frame, len) != ESP_OK) return false;
    if (xSemaphoreTake(s_send_sem, pdMS_TO_TICKS(SEND_WAIT_MS)) != pdTRUE) return false;
    return s_send_ok;
}

/* netcore TX hook: frames this node originates for a leaf (its ACKs) go over
 * ESP-NOW instead of the mesh. */
static bool tx_hook(const uint8_t *frame, size_t len, const uint8_t dst_mac[6], void *ctx)
{
    (void)ctx;
    if (siot_mac_is_bcast(dst_mac)) return false;
    lock();
    leaf_t *l = find_leaf(dst_mac);
    bool ok = false;
    if (l) ok = espnow_send_wait(l->peer, frame, len);
    unlock();
    if (l && !ok) ESP_LOGD(TAG, "type 0x%02X to a leaf: no MAC ACK (asleep?)", frame[4]);
    return l != NULL;
}

static void forward_up(const uint8_t *raw, size_t len)
{
    const esp_err_t err = siot_link_send(SIOT_LINK_MESH, SAFR_BCAST_MAC, raw, len);
    if (err == ESP_OK) s_stat_fwd++;
    else ESP_LOGW(TAG, "forward type 0x%02X up: %s", raw[4], esp_err_to_name(err));
}

/* ---- 2. uplink from a leaf ------------------------------------------------------ */

static void send_leaf_ack(leaf_t *l, uint16_t acked_msg_id, uint8_t code)
{
    uint8_t p[SIOT_LEAF_ACK_EXT_LEN];
    const uint8_t pending = siot_leaf_mailbox_count(&l->mailbox);
    const bool no_path = !siot_netcore_board_reachable();
    siot_leaf_ack_build(p, acked_msg_id, code, pending, no_path, siot_netcore_epoch(), siot_config_code()->channel);
    siot_safr_send(l->mac, SAFR_MSG_ACK, siot_safr_next_msg_id(), 0, p, sizeof(p)); /* → tx_hook → ESP-NOW */
    ESP_LOGI(TAG, "leaf ACK msg_id %u%s%s pending %u", acked_msg_id, no_path ? " NO_PATH" : "",
             siot_netcore_epoch() ? "" : " (no clock)", pending);
}

/* §12.5 drain: right after the ACK, the queued frames, oldest first, while the leaf answers at the MAC. */
static void drain_mailbox(leaf_t *l)
{
    for (int n = 0; n < SIOT_LEAF_MAILBOX_DRAIN_MAX; n++) {
        const siot_leaf_mail_t *m = siot_leaf_mailbox_oldest(&l->mailbox);
        if (m == NULL) return;
        if (!espnow_send_wait(l->peer, m->frame, m->len)) {
            ESP_LOGW(TAG, "mailbox: leaf went back to sleep, %u frame(s) wait", siot_leaf_mailbox_count(&l->mailbox));
            return;
        }
        ESP_LOGI(TAG, "mailbox: delivered type 0x%02X msg_id %u", m->frame[4], m->msg_id);
        siot_leaf_mailbox_remove(&l->mailbox, m);
    }
}

static void handle_leaf_frame(const rx_item_t *it)
{
    siot_safr_frame_t f;
    s_stat_rx++;
    switch (siot_safr_parse_frame(it->data, it->len, &f)) {
    case SIOT_SAFR_PARSE_OK: break;
    case SIOT_SAFR_PARSE_FOREIGN: s_stat_foreign++; return;
    case SIOT_SAFR_PARSE_AUTH_FAILED: s_stat_auth++; return;
    default: s_stat_bad++; return;
    }
    if ((f.flags & SAFR_F_ENC) == 0) return; /* plaintext never (spec §4.1) */

    lock();
    leaf_t *l = find_or_add_leaf(f.src_mac, it->src);
    memcpy(l->peer, it->src, 6);
    l->last_seen_ms = now_ms();
    l->rssi = it->rssi;
    const siot_leaf_rx_kind_t kind = siot_leaf_rx_check(&l->rx, f.boot_ctr, f.msg_ctr, f.msg_id);
    if (kind == SIOT_LEAF_RX_REPLAY) { s_stat_replay++; unlock(); return; }
    const bool dup = kind == SIOT_LEAF_RX_DUP;
    char m[SIOT_MAC_STR_LEN];
    ESP_LOGI(TAG, "leaf %s type 0x%02X msg_id %u at %d dBm%s", siot_mac_to_str(f.src_mac, m), f.msg_type, f.msg_id,
             it->rssi, dup ? " (retry)" : "");

    switch (f.msg_type) {
    case SAFR_MSG_HEARTBEAT:
        if (f.payload_len >= 20) l->battery = f.payload[9];
        send_leaf_ack(l, f.msg_id, SAFR_ACK_OK);
        if (!dup) forward_up(it->data, it->len);
        drain_mailbox(l);
        break;
    case SAFR_MSG_EVENT:
        send_leaf_ack(l, f.msg_id, SAFR_ACK_OK); /* custody (§12.6): from here on delivery is ours */
        if (!dup) {
            forward_up(it->data, it->len);
            const bool alarm = f.payload_len >= 1 && f.payload[0] == SAFR_EVT_ALARM;
            siot_leaf_custody_add(&s_custody, f.src_mac, f.msg_id, alarm, it->data, it->len, now_ms());
            ESP_LOGW(TAG, "custody: leaf EVENT type %u code %u msg_id %u (%u in custody)%s", f.payload[0],
                     f.payload_len > 1 ? f.payload[1] : 0, f.msg_id, siot_leaf_custody_count(&s_custody),
                     alarm ? " ALARM" : "");
        }
        drain_mailbox(l);
        break;
    case SAFR_MSG_ACK: /* the leaf acknowledged a mailbox frame: clear it, let the tablet see it */
        if (f.payload_len >= 4) siot_leaf_mailbox_ack(&l->mailbox, siot_get_u16(&f.payload[0]));
        if (!dup) forward_up(it->data, it->len);
        break;
    default: /* NAME_ANNOUNCE, TOPOLOGY, anything else: up it goes */
        if (f.flags & SAFR_F_ACK_REQ) send_leaf_ack(l, f.msg_id, SAFR_ACK_OK);
        if (!dup) forward_up(it->data, it->len);
        break;
    }
    unlock();
}

/* survey raw sink: ESP-NOW receive context — copy and leave. */
static void on_raw(const uint8_t src[6], int8_t rssi, const uint8_t *frame, size_t len, void *ctx)
{
    (void)ctx;
    if (len > SAFR_MAX_FRAME) return;
    rx_item_t it;
    memcpy(it.src, src, 6);
    it.rssi = rssi;
    it.len = (uint8_t)len;
    memcpy(it.data, frame, len);
    if (xQueueSend(s_rxq, &it, 0) != pdTRUE) ESP_LOGW(TAG, "rx queue full: leaf frame dropped");
}

/* ---- 3. downlink to a leaf --------------------------------------------------------- */

static void deliver_or_queue(leaf_t *l, const uint8_t *raw, size_t len, uint8_t cmd, uint16_t msg_id)
{
    const int64_t t = now_ms();
    if (t - l->last_seen_ms < AWAKE_WINDOW_MS && espnow_send_wait(l->peer, raw, len)) {
        ESP_LOGI(TAG, "downlink type 0x%02X msg_id %u delivered at once (leaf awake)", raw[4], msg_id);
        return;
    }
    const bool displaced = siot_leaf_mailbox_push(&l->mailbox, raw, len, cmd, msg_id, t);
    ESP_LOGI(TAG, "mailbox: queued type 0x%02X msg_id %u (%u waiting%s)", raw[4], msg_id,
             siot_leaf_mailbox_count(&l->mailbox), displaced ? ", one replaced/dropped" : "");
}

static void downlink_hook(const siot_safr_frame_t *f, const uint8_t *raw, size_t raw_len, bool dup, void *ctx)
{
    (void)ctx;
    if (dup) return;
    if (f->msg_type != SAFR_MSG_ACK && f->msg_type != SAFR_MSG_COMMAND) return; /* TIME_SYNC / board HEARTBEAT: never for a leaf (§12.5) */
    lock();
    if (f->msg_type == SAFR_MSG_ACK) {
        leaf_t *l = find_leaf(f->dst_mac);
        if (l && f->payload_len >= 4) {
            const uint16_t acked = siot_get_u16(&f->payload[0]);
            /* Only an ACK that closes an EVENT in custody goes to the leaf (its
             * cyan / end-to-end alarm ACK). The central also ACKs every leaf
             * HEARTBEAT it sees (spec §7.5); the leaf needs nothing from those,
             * and queueing them would cost it a mailbox drain on every wake. */
            if (siot_leaf_custody_ack(&s_custody, l->mac, acked)) {
                ESP_LOGI(TAG, "custody: msg_id %u confirmed by the board/central (%u left)", acked, siot_leaf_custody_count(&s_custody));
                deliver_or_queue(l, raw, raw_len, SIOT_LEAF_NOT_A_COMMAND, f->msg_id);
            } else {
                ESP_LOGD(TAG, "ACK msg_id %u for a leaf frame not in custody (heartbeat?): not forwarded", acked);
            }
        }
    } else {
        const uint8_t cmd = f->payload_len >= 1 ? f->payload[0] : SIOT_LEAF_NOT_A_COMMAND;
        if (cmd == SAFR_CMD_LINK_CHECK) { unlock(); return; } /* board-level supervision, not for leafs */
        if (siot_mac_is_bcast(f->dst_mac)) {
            for (int i = 0; i < MAX_LEAVES; i++) if (s_leaves[i].used) deliver_or_queue(&s_leaves[i], raw, raw_len, cmd, f->msg_id);
        } else {
            leaf_t *l = find_leaf(f->dst_mac);
            if (l) deliver_or_queue(l, raw, raw_len, cmd, f->msg_id);
        }
    }
    unlock();
}

/* ---- 4. task ------------------------------------------------------------------------ */

static void tick(void)
{
    const int64_t t = now_ms();
    lock();
    siot_leaf_custody_entry_t *e;
    while ((e = siot_leaf_custody_due(&s_custody, t)) != NULL) {
        forward_up(e->frame, e->len); /* identical bytes: the central ACKs every time (§9.1) */
        char m[SIOT_MAC_STR_LEN];
        ESP_LOGW(TAG, "custody: retry %u for leaf %s msg_id %u%s", e->attempts, siot_mac_to_str(e->leaf, m), e->msg_id,
                 e->alarm ? " (ALARM, never dropped)" : "");
        if (siot_leaf_custody_sent(&s_custody, e, t))
            ESP_LOGE(TAG, "custody: leaf %s msg_id %u gave up after the fast phase — no ACK from the board", siot_mac_to_str(e->leaf, m), e->msg_id);
    }
    for (int i = 0; i < MAX_LEAVES; i++) {
        leaf_t *l = &s_leaves[i];
        if (!l->used) continue;
        const uint8_t expired = siot_leaf_mailbox_expire(&l->mailbox, t);
        if (expired) ESP_LOGW(TAG, "mailbox: %u frame(s) expired unseen", expired);
        if (t - l->last_seen_ms > LEAF_TTL_MS) {
            char m[SIOT_MAC_STR_LEN];
            ESP_LOGW(TAG, "leaf %s silent for %d s: dropped from this parent", siot_mac_to_str(l->mac, m), LEAF_TTL_MS / 1000);
            l->used = false;
        }
    }
    unlock();
}

static void leafmgr_task(void *arg)
{
    (void)arg;
    int64_t next_tick = now_ms() + TICK_MS;
    for (;;) {
        rx_item_t it;
        const int64_t wait = next_tick - now_ms();
        if (xQueueReceive(s_rxq, &it, wait > 0 ? pdMS_TO_TICKS((uint32_t)wait) : 0) == pdTRUE) handle_leaf_frame(&it);
        if (now_ms() >= next_tick) { tick(); next_tick = now_ms() + TICK_MS; }
    }
}

/* ---- 5. init ------------------------------------------------------------------------ */

esp_err_t siot_leafmgr_init(void)
{
    s_lock = xSemaphoreCreateRecursiveMutex();
    s_rxq = xQueueCreate(RXQ_LEN, sizeof(rx_item_t));
    s_send_sem = xSemaphoreCreateBinary();
    if (!s_lock || !s_rxq || !s_send_sem) return ESP_ERR_NO_MEM;
    siot_leaf_custody_init(&s_custody);
    memset(s_leaves, 0, sizeof(s_leaves));
    esp_err_t err = esp_now_register_send_cb(on_espnow_sent);
    if (err != ESP_OK) { ESP_LOGE(TAG, "esp_now send cb: %s", esp_err_to_name(err)); return err; }
    siot_survey_set_raw_sink(on_raw, NULL);
    siot_netcore_set_tx_hook(tx_hook, NULL);
    siot_netcore_set_downlink_hook(downlink_hook, NULL);
    if (xTaskCreate(leafmgr_task, "siot_leafmgr", 6144, NULL, 6, NULL) != pdPASS) return ESP_ERR_NO_MEM;
    ESP_LOGI(TAG, "parent role ready: up to %d leafs, mailbox %d each, custody %d", MAX_LEAVES,
             SIOT_LEAF_MAILBOX_CAP, SIOT_LEAF_CUSTODY_CAP);
    return ESP_OK;
}

#endif /* CONFIG_SIOT_FEATURE_LEAFMGR */
