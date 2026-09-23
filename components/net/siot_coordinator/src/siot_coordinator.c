#include "siot_coordinator.h"

#include <string.h>

#include "esp_log.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "freertos/task.h"

#include "coord_internal.h"
#include "siot_config.h"
#include "siot_evbus.h"
#include "siot_identity.h"
#include "siot_link.h"
#include "siot_safr.h"
#include "siot_util.h"

static const char *TAG = "siot_coord";

#define HEARTBEAT_INTERVAL_MS 15000
#define TOPOLOGY_INTERVAL_MS  60000
#define CHILD_TIMEOUT_MS     180000 /* defined, not applied until the device_table (step 4) */
#define MAX_CHILDREN              8 /* AP max_connection */
#define JOURNAL_CAP              64 /* RAM ring (spec §8); flash-persisted in step 4 */
#define STEP_MS                 250

typedef struct { bool used; uint8_t mac[6]; int64_t last_seen_ms; } child_t;
typedef struct { uint32_t jrn_seq; uint8_t mac[6]; uint8_t payload[SAFR_EVENT_LEN]; } journal_entry_t;

static SemaphoreHandle_t s_lock;
static child_t         s_children[MAX_CHILDREN];
static journal_entry_t s_journal[JOURNAL_CAP];
static uint32_t        s_journal_top;             /* highest JRN_SEQ, 0 = none */
static siot_enrolled_entry_t s_enrolled[SIOT_MAX_ENROLLED];
static size_t          s_enrolled_n;
static siot_link_kind_t s_rx_kind;                /* which link the frame being dispatched came from */

static int64_t now_ms(void) { return esp_timer_get_time() / 1000; }

/* ---- TX: everything the board originates goes to the tablet ------------ */

static void tx_sink(const uint8_t *frame, size_t len, const uint8_t dst_mac[6], void *ctx)
{
    (void)ctx;
    /* The board originates COMMAND only for the network-wide TEST button, and
     * that goes downlink into the mesh. Everything else it originates
     * (HEARTBEAT, TOPOLOGY, ACK, INSTALLATION, EVENT_LOG_DATA) reports up to
     * the tablet. Relayed frames do not pass through here (see relay()). */
    const siot_link_kind_t kind = frame[4] == SAFR_MSG_COMMAND ? SIOT_LINK_MESH : SIOT_LINK_SERIAL;
    if (siot_link_send(kind, dst_mac, frame, len) == ESP_OK) {
        const siot_evt_frame_t ev = {.msg_type = frame[4]};
        siot_evbus_post(SIOT_EVT_SAFR_TX, &ev, sizeof(ev)); /* blue pulse on transmit */
    }
}

/* TEST button (system reference §3.5 row 5.3): broadcast a COMMAND TEST into
 * the mesh so every node raises its own MANUAL_TEST (a site-wide walk test).
 * The board raises no event of its own; the nodes' MANUAL_TEST frames flow
 * back up and are journaled + forwarded to the tablet. No F_ACK_REQ: the
 * MANUAL_TEST events are the confirmation, not a per-node command ACK. */
static void on_button(siot_evt_id_t id, const void *data, void *ctx)
{
    (void)data; (void)ctx;
    if (id != SIOT_EVT_BUTTON_TAP) return; /* double tap: no bench ALARM from the control unit */
    const uint8_t payload[2] = {SAFR_CMD_TEST, 0x00}; /* CMD, ARG_LEN = 0 */
    ESP_LOGW(TAG, "TEST tap -> broadcast COMMAND TEST to all nodes");
    siot_safr_set_level(0);
    siot_safr_send(SAFR_BCAST_MAC, SAFR_MSG_COMMAND, siot_safr_next_msg_id(), 0, payload, sizeof(payload));
}

/* A relayed frame (uplink to the tablet, downlink into the mesh): blue pulse + log. */
static void relay(siot_link_kind_t to, const uint8_t *raw, size_t raw_len)
{
    const esp_err_t err = siot_link_send(to, &raw[15], raw, raw_len);
    if (err == ESP_OK) {
        const siot_evt_frame_t ev = {.msg_type = raw[4]};
        siot_evbus_post(SIOT_EVT_SAFR_TX, &ev, sizeof(ev));
    } else {
        ESP_LOGW(TAG, "relay type 0x%02X to %s failed: %s", raw[4],
                 to == SIOT_LINK_MESH ? "mesh (no root connected?)" : "tablet", esp_err_to_name(err));
    }
}

static void send_to_tablet(uint8_t msg_type, const uint8_t dst[6], uint8_t flags,
                           const uint8_t *payload, size_t plen)
{
    siot_safr_send(dst, msg_type, siot_safr_next_msg_id(), flags, payload, plen);
}

static void send_ack(uint16_t acked_msg_id, uint8_t status, const uint8_t dst[6])
{
    uint8_t p[4] = {(uint8_t)(acked_msg_id >> 8), (uint8_t)acked_msg_id, status, 0x00};
    send_to_tablet(SAFR_MSG_ACK, dst, 0, p, sizeof(p));
}

/* ---- children (drives the TOPOLOGY shim) — lock held --------------------- */

static void track_child(const uint8_t mac[6], int64_t t)
{
    int free_slot = -1;
    for (int i = 0; i < MAX_CHILDREN; i++) {
        if (s_children[i].used && siot_mac_eq(s_children[i].mac, mac)) { s_children[i].last_seen_ms = t; return; }
        if (!s_children[i].used && free_slot < 0) free_slot = i;
    }
    if (free_slot < 0) return;
    s_children[free_slot].used = true;
    memcpy(s_children[free_slot].mac, mac, 6);
    s_children[free_slot].last_seen_ms = t;
}

/* ---- journal (spec §8) — lock held ---------------------------------------- */

static void journal_append(const uint8_t mac[6], const uint8_t payload[SAFR_EVENT_LEN])
{
    journal_entry_t *j = &s_journal[s_journal_top % JOURNAL_CAP];
    j->jrn_seq = ++s_journal_top;
    memcpy(j->mac, mac, 6);
    memcpy(j->payload, payload, SAFR_EVENT_LEN);
}

/* EVENT_LOG_REQ → EVENT_LOG_DATA (spec §7.8 / §7.9). */
static void send_journal(uint32_t since_seq, uint8_t max_count, const uint8_t dst[6])
{
    if (max_count == 0 || max_count > SAFR_LOG_BATCH_DEF) max_count = SAFR_LOG_BATCH_DEF;
    const uint32_t oldest = s_journal_top > JOURNAL_CAP ? s_journal_top - JOURNAL_CAP + 1 : 1;
    uint32_t seq = since_seq + 1 < oldest ? oldest : since_seq + 1;
    uint8_t p[SAFR_LOG_DATA_LEN];

    if (seq > s_journal_top) { /* nothing newer */
        memset(p, 0, sizeof(p));
        siot_put_u32(&p[0], s_journal_top);
        p[4] = SAFR_LOG_F_LAST | SAFR_LOG_F_EMPTY;
        send_to_tablet(SAFR_MSG_EVENT_LOG_DATA, dst, 0, p, sizeof(p));
        return;
    }
    for (uint8_t sent = 0; seq <= s_journal_top && sent < max_count; seq++, sent++) {
        const journal_entry_t *j = &s_journal[(seq - 1) % JOURNAL_CAP];
        siot_put_u32(&p[0], j->jrn_seq);
        p[4] = (seq == s_journal_top || sent == max_count - 1) ? SAFR_LOG_F_LAST : 0;
        memcpy(&p[5], j->mac, 6);
        memcpy(&p[11], j->payload, SAFR_EVENT_LEN);
        send_to_tablet(SAFR_MSG_EVENT_LOG_DATA, dst, 0, p, sizeof(p));
    }
}

static void send_installation(const uint8_t dst[6])
{
    uint8_t p[SAFR_MAX_PAYLOAD];
    const size_t plen = coord_installation_encode(siot_config_code(), s_enrolled, s_enrolled_n, p);
    send_to_tablet(SAFR_MSG_INSTALLATION, dst, 0, p, plen);
}

/* ---- uplink (mesh → tablet) ------------------------------------------------ */

static void handle_uplink(const siot_safr_frame_t *f, const uint8_t *raw, size_t raw_len, bool dup)
{
    xSemaphoreTake(s_lock, portMAX_DELAY);
    track_child(f->src_mac, now_ms());
    if (!dup && f->msg_type == SAFR_MSG_EVENT && f->payload_len == SAFR_EVENT_LEN) {
        journal_append(f->src_mac, f->payload);
    }
    xSemaphoreGive(s_lock);
    /* Forwarded unchanged, fast retries included: the tablet ACKs every time. */
    relay(SIOT_LINK_SERIAL, raw, raw_len);
}

/* ---- downlink (tablet → board / mesh) -------------------------------------- */

static void handle_downlink(const siot_safr_frame_t *f, const uint8_t *raw, size_t raw_len, bool dup)
{
    if (f->msg_type == SAFR_MSG_COMMAND && f->payload_len >= 1 &&
        f->payload[0] == SAFR_CMD_GET_INSTALLATION) {
        xSemaphoreTake(s_lock, portMAX_DELAY);
        send_installation(f->src_mac); /* the reply is the confirmation */
        xSemaphoreGive(s_lock);
        return;
    }
    switch (f->msg_type) {
    case SAFR_MSG_COMMAND:   /* LINK_CHECK and every device command */
    case SAFR_MSG_TIME_SYNC:
        send_ack(f->msg_id, SAFR_ACK_OK, f->src_mac);          /* board ACKs every time */
        if (!dup) relay(SIOT_LINK_MESH, raw, raw_len);         /* nodes ACK on their own */
        return;
    case SAFR_MSG_EVENT_LOG_REQ:
        if (f->payload_len >= 5) {
            xSemaphoreTake(s_lock, portMAX_DELAY);
            send_journal(siot_get_u32(&f->payload[0]), f->payload[4], f->src_mac);
            xSemaphoreGive(s_lock);
        }
        return;
    case SAFR_MSG_ACK:
        if (!dup) relay(SIOT_LINK_MESH, raw, raw_len); /* the §14 item 4 fix */
        return;
    default:
        return; /* unknown downlink type: dropped */
    }
}

static void on_frame(const siot_safr_frame_t *f, const uint8_t *raw, size_t raw_len, bool dup, void *ctx)
{
    (void)ctx;
    if (s_rx_kind == SIOT_LINK_MESH) handle_uplink(f, raw, raw_len, dup);
    else handle_downlink(f, raw, raw_len, dup);
}

/* Both links deliver here (their own tasks); the dispatcher is keyed by
 * MSG_TYPE only, so remember the link for the handler. Each link's rx runs
 * in its own task, so the pair (set kind, dispatch) is serialised by s_rx_lock. */
static SemaphoreHandle_t s_rx_lock;

static void on_link_rx(siot_link_kind_t kind, const uint8_t *frame, size_t len, void *ctx)
{
    (void)ctx;
    xSemaphoreTake(s_rx_lock, portMAX_DELAY);
    s_rx_kind = kind;
    const siot_safr_rx_result_t r = siot_safr_rx(frame, len);
    xSemaphoreGive(s_rx_lock);
    char src[SIOT_MAC_STR_LEN];
    ESP_LOGI(TAG, "rx %s type 0x%02X id %u from %s: %d", kind == SIOT_LINK_MESH ? "mesh" : "tablet",
             frame[4], siot_get_u16(&frame[5]), siot_mac_to_str(&frame[9], src), (int)r);
    if (r == SIOT_SAFR_RX_OK || r == SIOT_SAFR_RX_DUPLICATE) {
        siot_evt_frame_t ev = {.msg_type = frame[4]};
        memcpy(ev.src_mac, &frame[9], 6);
        siot_evbus_post(SIOT_EVT_SAFR_RX, &ev, sizeof(ev));
    }
}

/* ---- HEARTBEAT / TOPOLOGY compatibility shim (brief §8) ------------------- */

static void emit_heartbeat(void)
{
    uint8_t p[20];
    siot_put_u32(&p[0], 0);                                /* wall clock: TIME_SYNC, step 4 */
    siot_put_u32(&p[4], (uint32_t)(esp_timer_get_time() / 1000000));
    p[8] = SAFR_PWR_AC_OK;
    p[9] = SAFR_NA_U8;
    siot_put_u16(&p[10], (uint16_t)SAFR_NA_I16);
    p[12] = (uint8_t)SAFR_NA_RSSI;
    memcpy(&p[13], SAFR_CENTRAL_MAC, 6);
    p[19] = 0; /* LAYER 0 */
    send_to_tablet(SAFR_MSG_HEARTBEAT, SAFR_BCAST_MAC, 0, p, sizeof(p));
}

static void emit_topology(int64_t t)
{
    uint8_t p[SAFR_MAX_PAYLOAD];
    siot_put_u32(&p[0], (uint32_t)(t / 1000));
    p[4] = SAFR_ROLE_ROOT;
    p[5] = 0;
    memcpy(&p[6], SAFR_CENTRAL_MAC, 6);
    p[12] = (uint8_t)SAFR_NA_RSSI;
    size_t off = 14;
    uint8_t count = 0;
    xSemaphoreTake(s_lock, portMAX_DELAY);
    for (int i = 0; i < MAX_CHILDREN; i++) {
        if (!s_children[i].used) continue;
        memcpy(&p[off], s_children[i].mac, 6);
        p[off + 6] = (uint8_t)SAFR_NA_RSSI; /* the board does not see mesh-internal RSSI */
        off += 7;
        count++;
    }
    xSemaphoreGive(s_lock);
    p[13] = count;
    send_to_tablet(SAFR_MSG_TOPOLOGY, SAFR_BCAST_MAC, 0, p, off);
}

static void coordinator_task(void *arg)
{
    (void)arg;
    int64_t next_hb_ms = 0, next_topo_ms = 0;
    for (;;) {
        const int64_t t = now_ms();
        if (t >= next_hb_ms) { emit_heartbeat(); next_hb_ms = t + HEARTBEAT_INTERVAL_MS; }
        if (t >= next_topo_ms) { emit_topology(t); next_topo_ms = t + TOPOLOGY_INTERVAL_MS; }
        vTaskDelay(pdMS_TO_TICKS(STEP_MS));
    }
}

esp_err_t siot_coordinator_start(void)
{
    if (!siot_config_has_code() || !siot_identity_valid()) return ESP_ERR_INVALID_STATE;
    if (s_lock == NULL) s_lock = xSemaphoreCreateMutex();
    if (s_rx_lock == NULL) s_rx_lock = xSemaphoreCreateMutex();
    s_enrolled_n = siot_config_load_enrolled(s_enrolled, SIOT_MAX_ENROLLED);
    ESP_LOGI(TAG, "enrolled devices: %u", (unsigned)s_enrolled_n);

    /* One handler for every Phase 1 type; the link kind tells up from down. */
    for (uint8_t t = SAFR_MSG_EVENT; t <= SAFR_MSG_NAME_ANNOUNCE; t++) {
        const esp_err_t err = siot_safr_register(t, on_frame, NULL);
        if (err != ESP_OK) return err;
    }
    siot_safr_set_level(0);
    siot_safr_set_tx(tx_sink, NULL);
    siot_link_set_rx(on_link_rx, NULL);
    esp_err_t err = siot_evbus_subscribe(SIOT_EVT_BUTTON_TAP, on_button, NULL, NULL);
    if (err != ESP_OK) return err;

    err = siot_link_start(SIOT_LINK_SERIAL);
    if (err != ESP_OK) return err;
    err = siot_link_start(SIOT_LINK_MESH);
    if (err != ESP_OK) return err;

    if (xTaskCreatePinnedToCore(coordinator_task, "coordinator", 4096, NULL, 14, NULL, 0) != pdPASS) {
        return ESP_ERR_NO_MEM;
    }
    const siot_evt_state_t ev = {.prev = SIOT_STATE_SETUP, .next = SIOT_STATE_ONLINE};
    siot_evbus_post(SIOT_EVT_STATE_CHANGED, &ev, sizeof(ev));
    return ESP_OK;
}
