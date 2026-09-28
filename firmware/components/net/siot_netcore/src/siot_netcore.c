#include "siot_netcore.h"

#include <string.h>

#include "esp_log.h"
#include "esp_system.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "freertos/task.h"

#include "siot_config.h"
#include "siot_evbus.h"
#include "siot_identity.h"
#include "siot_link.h"
#include "siot_safr.h"
#include "siot_survey.h"
#include "siot_util.h"

static const char *TAG = "siot_netcore";

#define HB_INTERVAL_MS    15000 /* spec §9.2 */
#define TOPO_INTERVAL_MS  60000
#define ALARM_RETX_MS     60000 /* spec §7.2 */
#define RETRY_BACKOFF_MS   2000 /* spec §9.1 */
#define RETRY_MAX             3
#define STEP_MS             250
#define MAX_CHILDREN         16
#define DEFAULT_EPOCH 0x686E2Fu /* until TIME_SYNC arrives (same placeholder as the POC) */

static SemaphoreHandle_t s_lock;
static TaskHandle_t s_task;

static uint32_t s_epoch_base = DEFAULT_EPOCH;
static int64_t  s_epoch_ref_ms;

static siot_state_t s_state = SIOT_STATE_JOINING;
static uint8_t      s_level_seen = 0xFF;
static bool         s_comm_fault;

static bool     s_alarm_active;
static uint8_t  s_alarm_payload[SAFR_EVENT_LEN];
static int64_t  s_alarm_next_retx_ms;

/* One in-flight critical uplink awaiting ACK (fast phase). Step 4 turns this
 * into the ALARM-first queue (brief §14 item 13). */
static bool     s_pending_used;
static uint16_t s_pending_msg_id;
static uint8_t  s_pending_payload[SAFR_EVENT_LEN];
static uint8_t  s_pending_attempts;
static int64_t  s_pending_next_ms;

static bool s_name_announced;
static esp_timer_handle_t s_decommission_timer;

/* Role announcement after a Mesh-Lite level change (brief §9: "TOPOLOGY 60 s
 * + on change"). It used to fire once, at the instant of the change — before
 * the new root had its TCP session, before a child's new root could forward —
 * and was silently lost, so the tablet saw nothing until the next 15 s tick
 * and the old tree stayed on screen. Now it stays pending until the path is
 * proven (root: board session up; child: a downlink frame arrived after the
 * change) and the frames actually left. */
static bool    s_announce_pending;
static int64_t s_level_change_ms;
static bool    s_last_tx_ok; /* result of the last HEARTBEAT/TOPOLOGY send (netcore task only) */


static int64_t now_ms(void) { return esp_timer_get_time() / 1000; }
static uint32_t now_epoch(int64_t t) { return s_epoch_base + (uint32_t)((t - s_epoch_ref_ms) / 1000); }

/* When a downlink frame last came through: the board's own HEARTBEAT every
 * 15 s (spec §7.3 — the steady signal, tablet or not), TIME_SYNC / LINK_CHECK
 * from the tablet, ACKs and commands from the board. Two nodes can form a
 * mesh among themselves with no board at all (Mesh-Lite picks a root
 * anyway), so "level > 0" never meant "the board is there". */
static int64_t s_last_downlink_ms = -1;
#define BOARD_SILENCE_MS 90000 /* 6 missed board HEARTBEATs = 3 × the tablet's LINK_CHECK (spec §9.3) */

static bool board_reachable(int64_t t)
{
    if (siot_link_mesh_level() == 1 && siot_link_mesh_board_up()) return true;
    return s_last_downlink_ms >= 0 && t - s_last_downlink_ms < BOARD_SILENCE_MS;
}

/* Runs in the link rx task for every downlink frame (before for_me). */
static void note_downlink(void)
{
    const int64_t t = now_ms();
    const bool was = board_reachable(t);
    s_last_downlink_ms = t;
    if (!was) {
        ESP_LOGI(TAG, "board reachable: re-announcing name");
        xSemaphoreTake(s_lock, portMAX_DELAY);
        s_name_announced = false; /* the announce sent into a board-less mesh was lost */
        xSemaphoreGive(s_lock);
    }
}

static void post_state(siot_state_t next)
{
    if (next == s_state) return;
    const siot_evt_state_t ev = {.prev = (uint8_t)s_state, .next = (uint8_t)next};
    ESP_LOGI(TAG, "state %u -> %u", s_state, next);
    s_state = next;
    siot_evbus_post(SIOT_EVT_STATE_CHANGED, &ev, sizeof(ev));
}

/* ---- TX ---------------------------------------------------------------- */

static siot_netcore_tx_hook_t       s_tx_hook;
static void                        *s_tx_hook_ctx;
static siot_netcore_downlink_hook_t s_dl_hook;
static void                        *s_dl_hook_ctx;

void siot_netcore_set_tx_hook(siot_netcore_tx_hook_t hook, void *ctx) { s_tx_hook = hook; s_tx_hook_ctx = ctx; }
void siot_netcore_set_downlink_hook(siot_netcore_downlink_hook_t hook, void *ctx) { s_dl_hook = hook; s_dl_hook_ctx = ctx; }
bool siot_netcore_board_reachable(void) { return board_reachable(now_ms()); }
uint32_t siot_netcore_epoch(void) { return s_epoch_base ? now_epoch(now_ms()) : 0; }

/* siot_safr's TX sink: onto the mesh link, one blue pulse when it left. */
static void tx_sink(const uint8_t *frame, size_t len, const uint8_t dst_mac[6], void *ctx)
{
    (void)ctx;
    if (siot_survey_tx(frame, len, dst_mac)) return; /* PARENT_PROBE/OFFER: ESP-NOW, not the mesh */
    if (s_tx_hook && s_tx_hook(frame, len, dst_mac, s_tx_hook_ctx)) return; /* a leaf's: ESP-NOW (§12) */
    const esp_err_t err = siot_link_send(SIOT_LINK_MESH, dst_mac, frame, len);
    const bool reachable = board_reachable(now_ms());
    if (frame[4] == SAFR_MSG_HEARTBEAT || frame[4] == SAFR_MSG_TOPOLOGY) s_last_tx_ok = err == ESP_OK;
    if (err == ESP_OK) {
        /* Blue traffic tick only when the frame can actually reach the tablet;
         * inside a board-less mesh it would just be noise on the LED. */
        if (reachable) {
            const siot_evt_frame_t ev = {.msg_type = frame[4]};
            siot_evbus_post(SIOT_EVT_SAFR_TX, &ev, sizeof(ev));
        }
        ESP_LOGD(TAG, "tx type 0x%02X id %u", frame[4], siot_get_u16(&frame[5]));
    } else if (reachable) {
        ESP_LOGW(TAG, "tx type 0x%02X id %u NOT sent: %s (level %u, board %s)", frame[4],
                 siot_get_u16(&frame[5]), esp_err_to_name(err), siot_link_mesh_level(),
                 siot_link_mesh_board_up() ? "up" : "down");
    } else {
        ESP_LOGD(TAG, "tx type 0x%02X dropped: no path to the board yet", frame[4]);
    }
}

static esp_err_t send_uplink(uint8_t msg_type, uint16_t msg_id, uint8_t flags,
                             const uint8_t *payload, size_t plen)
{
    siot_safr_set_level(siot_link_mesh_level());
    return siot_safr_send(SAFR_BCAST_MAC, msg_type, msg_id, flags, payload, plen);
}

static void send_ack(uint16_t acked_msg_id, uint8_t status, const uint8_t dst[6])
{
    uint8_t p[4] = {(uint8_t)(acked_msg_id >> 8), (uint8_t)acked_msg_id, status, 0x00};
    siot_safr_set_level(siot_link_mesh_level());
    siot_safr_send(dst, SAFR_MSG_ACK, siot_safr_next_msg_id(), 0, p, sizeof(p));
}

/* ---- EVENT (spec §7.1) ---------------------------------------------------- */

static void build_event_payload(uint8_t *p, int64_t t, uint8_t evt_type, uint8_t evt_code)
{
    p[0] = evt_type;
    p[1] = evt_code;
    siot_put_u32(&p[2], now_epoch(t));
    p[6] = SAFR_PWR_AC_OK | SAFR_PWR_CHARGING; /* AC device (brief §5.4) */
    p[7] = SAFR_NA_U8;                          /* BATTERY_PCT */
    siot_put_u16(&p[8], SAFR_NA_U16);           /* SMOKE */
    siot_put_u16(&p[10], (uint16_t)SAFR_NA_I16);/* TEMP */
    p[12] = SAFR_NA_U8;                         /* HUMIDITY */
    p[13] = 0;                                  /* FAULT_FLAGS */
    p[14] = 0;                                  /* FAULT_CODE */
    siot_put_u16(&p[15], siot_config_dev_seq_next());
}

/* lock held */
static void emit_event(int64_t t, uint8_t evt_type, uint8_t evt_code, bool ack_req, bool track)
{
    uint8_t payload[SAFR_EVENT_LEN];
    build_event_payload(payload, t, evt_type, evt_code);
    const uint16_t msg_id = siot_safr_next_msg_id();
    ESP_LOGI(TAG, "EVENT type %u code %u msg_id %u dev_seq %u%s", evt_type, evt_code, msg_id,
             siot_get_u16(&payload[15]), ack_req ? " (ACK required)" : "");
    send_uplink(SAFR_MSG_EVENT, msg_id, ack_req ? SAFR_F_ACK_REQ : 0, payload, sizeof(payload));

    if (evt_type == SAFR_EVT_ALARM) {
        s_alarm_active = true;
        memcpy(s_alarm_payload, payload, SAFR_EVENT_LEN);
        s_alarm_next_retx_ms = t + ALARM_RETX_MS;
        siot_evbus_post(SIOT_EVT_ALARM_SET, NULL, 0);
    }
    if (ack_req && track) {
        s_pending_used = true;
        s_pending_msg_id = msg_id;
        memcpy(s_pending_payload, payload, SAFR_EVENT_LEN);
        s_pending_attempts = 1;
        s_pending_next_ms = t + RETRY_BACKOFF_MS;
    }
}

/* ---- HEARTBEAT (§7.3) / TOPOLOGY (§7.4) / NAME_ANNOUNCE (§7.11) ---------- */

static void emit_heartbeat(int64_t t)
{
    uint8_t p[20];
    siot_put_u32(&p[0], now_epoch(t));
    siot_put_u32(&p[4], (uint32_t)(t / 1000)); /* UPTIME_S */
    p[8] = SAFR_PWR_AC_OK | SAFR_PWR_CHARGING;
    p[9] = SAFR_NA_U8;
    siot_put_u16(&p[10], (uint16_t)SAFR_NA_I16);
    uint8_t parent[6];
    int8_t rssi;
    if (siot_link_mesh_parent(parent, &rssi)) { /* root: the board's AP, still a real hop */
        p[12] = (uint8_t)rssi;
        memcpy(&p[13], parent, 6);
    } else {
        p[12] = (uint8_t)SAFR_NA_RSSI;
        memset(&p[13], 0, 6);
    }
    p[19] = siot_link_mesh_level();
    send_uplink(SAFR_MSG_HEARTBEAT, siot_safr_next_msg_id(), 0, p, sizeof(p));
}

static void emit_topology(int64_t t)
{
    uint8_t p[SAFR_MAX_PAYLOAD];
    siot_put_u32(&p[0], now_epoch(t));
    p[4] = siot_link_mesh_level() == 1 ? SAFR_ROLE_ROOT : SAFR_ROLE_NODE;
    p[5] = siot_link_mesh_level();
    uint8_t parent[6];
    int8_t rssi;
    if (siot_link_mesh_parent(parent, &rssi)) {
        memcpy(&p[6], parent, 6);
        p[12] = (uint8_t)rssi;
    } else {
        memset(&p[6], 0, 6);
        p[12] = (uint8_t)SAFR_NA_RSSI;
    }
    uint8_t macs[MAX_CHILDREN][6];
    int8_t rssis[MAX_CHILDREN];
    const size_t count = siot_link_mesh_children(macs, rssis, MAX_CHILDREN);
    p[13] = (uint8_t)count;
    size_t off = 14;
    for (size_t i = 0; i < count && off + 7 <= SAFR_MAX_PAYLOAD; i++) {
        memcpy(&p[off], macs[i], 6);
        p[off + 6] = (uint8_t)rssis[i];
        off += 7;
    }
    send_uplink(SAFR_MSG_TOPOLOGY, siot_safr_next_msg_id(), 0, p, off);
}

static bool emit_name_announce(void)
{
    const siot_installation_t *code = siot_config_code();
    uint8_t p[1 + SIOT_NAME_MAX_LEN + 1 + SIOT_ZONE_MAX_LEN + 1];
    const uint8_t name_len = (uint8_t)strnlen(code->name, SIOT_NAME_MAX_LEN);
    const uint8_t zone_len = (uint8_t)strnlen(code->zone, SIOT_ZONE_MAX_LEN);
    size_t off = 0;
    p[off++] = name_len;
    memcpy(&p[off], code->name, name_len); off += name_len;
    p[off++] = zone_len;
    memcpy(&p[off], code->zone, zone_len); off += zone_len;
    p[off++] = siot_link_mesh_level() == 1 ? SAFR_ROLE_ROOT : SAFR_ROLE_NODE; /* v3.2 ROLE */
    return send_uplink(SAFR_MSG_NAME_ANNOUNCE, siot_safr_next_msg_id(), 0, p, off) == ESP_OK;
}

/* ---- downlink handlers (run in the link rx task, lock taken here) ------- */

static bool for_me(const siot_safr_frame_t *f)
{
    return siot_mac_eq(f->dst_mac, siot_identity_get()->mac) || siot_mac_is_bcast(f->dst_mac);
}

/* Every distinct downlink frame goes one hop further to our children (brief
 * §6.3): the dedupe in siot_safr makes this loop-safe. */
static void relay_down(const siot_safr_frame_t *f, const uint8_t *raw, size_t raw_len, bool duplicate)
{
    if (!duplicate) siot_link_mesh_broadcast_children(raw, raw_len);
    if (s_dl_hook) s_dl_hook(f, raw, raw_len, duplicate, s_dl_hook_ctx); /* leafs behind this node (§12.5) */
}

static void on_ack(const siot_safr_frame_t *f, const uint8_t *raw, size_t raw_len, bool dup, void *ctx)
{
    (void)ctx;
    note_downlink();
    relay_down(f, raw, raw_len, dup);
    if (!for_me(f) || f->payload_len < 4) return;
    const uint16_t acked = siot_get_u16(&f->payload[0]);
    const siot_evt_ack_t ev = {.msg_id = acked, .status = f->payload[2]};
    xSemaphoreTake(s_lock, portMAX_DELAY);
    ESP_LOGI(TAG, "ACK for msg_id %u status %u (%s)", acked, f->payload[2],
             s_pending_used && s_pending_msg_id == acked ? "confirms the pending frame"
             : s_pending_used ? "pending is another id" : "nothing pending");
    if (s_pending_used && s_pending_msg_id == acked) s_pending_used = false;
    if (s_comm_fault) { /* the uplink works again: RESTORE (brief §9) */
        s_comm_fault = false;
        emit_event(now_ms(), SAFR_EVT_OK, SAFR_EC_RESTORE, false, false);
    }
    xSemaphoreGive(s_lock);
    siot_evbus_post(SIOT_EVT_ACK_RECEIVED, &ev, sizeof(ev));
}

/* The board's HEARTBEAT (spec §7.3): only ever reaches a node downlink (a
 * node's own uplink HEARTBEATs go root → TCP, never back into the tree), so
 * it is proof the board is behind the mesh. Relay it one hop further. */
static void on_board_heartbeat(const siot_safr_frame_t *f, const uint8_t *raw, size_t raw_len, bool dup, void *ctx)
{
    (void)f; (void)ctx;
    note_downlink();
    relay_down(f, raw, raw_len, dup);
}

static void on_time_sync(const siot_safr_frame_t *f, const uint8_t *raw, size_t raw_len, bool dup, void *ctx)
{
    (void)ctx;
    note_downlink();
    relay_down(f, raw, raw_len, dup);
    if (!for_me(f) || f->payload_len < 5) return;
    if (!dup) {
        xSemaphoreTake(s_lock, portMAX_DELAY);
        s_epoch_base = siot_get_u32(&f->payload[0]);
        s_epoch_ref_ms = now_ms();
        xSemaphoreGive(s_lock);
        const siot_evt_time_t ev = {.epoch = s_epoch_base, .tz_offset_qh = (int8_t)f->payload[4]};
        siot_evbus_post(SIOT_EVT_TIME_SYNCED, &ev, sizeof(ev));
    }
    if (f->flags & SAFR_F_ACK_REQ) send_ack(f->msg_id, SAFR_ACK_OK, f->src_mac); /* every time */
}

/* DECOMMISSION (spec §7.6 v3.2): the ACK went out first; now wipe the code
 * and come back in setup mode. Runs in the esp_timer task, not the rx path. */
static void decommission_cb(void *arg)
{
    (void)arg;
    ESP_LOGW(TAG, "DECOMMISSION: erasing the code, back to setup mode");
    siot_evbus_post(SIOT_EVT_FACTORY_RESET, NULL, 0);
    siot_config_factory_reset();
    vTaskDelay(pdMS_TO_TICKS(200)); /* let the LED/log settle */
    esp_restart();
}

/* SET_DEVICE ARGS: mac[6] ‖ name_len ‖ name ‖ zone_len ‖ zone; must name us. */
static bool apply_set_device(const uint8_t *a, size_t alen)
{
    if (alen < 8 || !siot_mac_eq(a, siot_identity_get()->mac)) return false;
    const size_t n = a[6];
    if (n > SIOT_NAME_MAX_LEN || 7 + n >= alen) return false;
    const size_t z = a[7 + n];
    if (z > SIOT_ZONE_MAX_LEN || 8 + n + z != alen) return false;
    siot_installation_t inst = *siot_config_code();
    memset(inst.name, 0, sizeof(inst.name));
    memset(inst.zone, 0, sizeof(inst.zone));
    memcpy(inst.name, &a[7], n);
    memcpy(inst.zone, &a[8 + n], z);
    if (siot_config_save_code(&inst) != ESP_OK) return false;
    ESP_LOGW(TAG, "SET_DEVICE: now \"%s\" / \"%s\" — re-announcing", inst.name, inst.zone);
    xSemaphoreTake(s_lock, portMAX_DELAY);
    s_name_announced = false;
    xSemaphoreGive(s_lock);
    return true;
}

static void on_command(const siot_safr_frame_t *f, const uint8_t *raw, size_t raw_len, bool dup, void *ctx)
{
    (void)ctx;
    note_downlink();
    relay_down(f, raw, raw_len, dup);
    if (!for_me(f) || f->payload_len < 2) return;
    const uint8_t cmd = f->payload[0];
    const size_t alen = f->payload[1];
    const uint8_t *args = &f->payload[2];
    if (f->payload_len < 2 + alen) return;
    uint8_t status = SAFR_ACK_OK;
    if (!dup) { /* process once */
        switch (cmd) {
        case SAFR_CMD_LINK_CHECK: /* board-level supervision no-op (spec §9.3) */
            break;
        case SAFR_CMD_SET_DEVICE: /* v3.2: rename / re-zone (lifecycle §5 H) */
            if (!apply_set_device(args, alen)) status = SAFR_ACK_ERROR;
            break;
        case SAFR_CMD_DECOMMISSION: /* v3.2: remote factory reset (lifecycle §5 G) */
            if (alen != 6 || siot_mac_is_bcast(f->dst_mac) ||
                !siot_mac_eq(f->dst_mac, siot_identity_get()->mac) || !siot_mac_eq(args, f->dst_mac)) {
                status = SAFR_ACK_ERROR; /* never broadcast, ARGS must equal DST == us */
                break;
            }
            if (s_decommission_timer == NULL) {
                const esp_timer_create_args_t targs = {.callback = decommission_cb, .name = "decommission"};
                esp_timer_create(&targs, &s_decommission_timer);
            }
            if (s_decommission_timer) esp_timer_start_once(s_decommission_timer, 300 * 1000);
            break;
        case SAFR_CMD_IDENTIFY: {
            const siot_evt_identify_t ev = {.seconds = f->payload_len >= 3 ? f->payload[2] : 0};
            siot_evbus_post(SIOT_EVT_IDENTIFY, &ev, sizeof(ev));
            break;
        }
        case SAFR_CMD_TEST:
            xSemaphoreTake(s_lock, portMAX_DELAY);
            emit_event(now_ms(), SAFR_EVT_ALERT, SAFR_EC_MANUAL_TEST, true, true);
            xSemaphoreGive(s_lock);
            break;
        case SAFR_CMD_RESET:
            xSemaphoreTake(s_lock, portMAX_DELAY);
            s_alarm_active = false;
            s_pending_used = false;
            xSemaphoreGive(s_lock);
            siot_evbus_post(SIOT_EVT_ALARM_CLEARED, NULL, 0);
            break;
        case SAFR_CMD_SILENCE:
        case SAFR_CMD_RELAY_SET:
        default:
            break; /* no sounder / relay in Phase 1 */
        }
    }
    if (f->flags & SAFR_F_ACK_REQ) send_ack(f->msg_id, status, f->src_mac); /* ACK every time */
}

/* Link rx (mesh_tcp_task or Mesh-Lite's task) → the SAFR pipeline. */
static const char *rx_result_name(siot_safr_rx_result_t r)
{
    switch (r) {
    case SIOT_SAFR_RX_OK:                 return "ok";
    case SIOT_SAFR_RX_DUPLICATE:          return "duplicate";
    case SIOT_SAFR_RX_NO_HANDLER:         return "no handler";
    case SIOT_SAFR_RX_BAD_FRAME:          return "bad frame";
    case SIOT_SAFR_RX_FOREIGN:            return "foreign SYSTEM_ID";
    case SIOT_SAFR_RX_PLAINTEXT_REJECTED: return "plaintext rejected";
    case SIOT_SAFR_RX_AUTH_FAILED:        return "auth failed (key?)";
    case SIOT_SAFR_RX_REPLAY:             return "replay";
    default:                              return "not initialised";
    }
}

static void on_link_rx(siot_link_kind_t kind, const uint8_t *frame, size_t len, void *ctx)
{
    (void)kind; (void)ctx;
    const siot_safr_rx_result_t r = siot_safr_rx(frame, len);
    char src[SIOT_MAC_STR_LEN], dst[SIOT_MAC_STR_LEN];
    ESP_LOGI(TAG, "rx type 0x%02X id %u from %s to %s: %s", frame[4], siot_get_u16(&frame[5]),
             siot_mac_to_str(&frame[9], src), siot_mac_to_str(&frame[15], dst), rx_result_name(r));
    if (r == SIOT_SAFR_RX_OK || r == SIOT_SAFR_RX_DUPLICATE) {
        siot_evt_frame_t ev = {.msg_type = frame[4]};
        memcpy(ev.src_mac, &frame[9], 6);
        siot_evbus_post(SIOT_EVT_SAFR_RX, &ev, sizeof(ev));
    }
}

/* ---- button ------------------------------------------------------------ */

static void on_button(siot_evt_id_t id, const void *data, void *ctx)
{
    (void)data; (void)ctx;
    if (id == SIOT_EVT_BUTTON_TAP && !board_reachable(now_ms())) {
        /* No path to the board (no mesh, or a board-less mesh between nodes):
         * TEST is the range survey (lifecycle §6), not a walk test. */
        ESP_LOGW(TAG, "TEST tap with no board reachable (level %u) -> survey probe", siot_link_mesh_level());
        const esp_err_t err = siot_survey_probe();
        if (err != ESP_OK && err != ESP_ERR_INVALID_STATE) ESP_LOGW(TAG, "survey: %s", esp_err_to_name(err));
        return; /* INVALID_STATE = locked, already logged by siot_survey */
    }
    xSemaphoreTake(s_lock, portMAX_DELAY);
    if (id == SIOT_EVT_BUTTON_TAP) {
        ESP_LOGW(TAG, "TEST tap (level %u) -> MANUAL_TEST", siot_link_mesh_level());
        emit_event(now_ms(), SAFR_EVT_ALERT, SAFR_EC_MANUAL_TEST, true, true);
    } else if (id == SIOT_EVT_BUTTON_DOUBLE_TAP) {
        ESP_LOGW(TAG, "double tap -> ALARM SMOKE_ALARM");
        emit_event(now_ms(), SAFR_EVT_ALARM, SAFR_EC_SMOKE_ALARM, true, true);
    }
    xSemaphoreGive(s_lock);
}

/* ---- state machine (brief §3) ------------------------------------------- */

/* Returns true when the Mesh-Lite level (and thus our role) just changed, so
 * the caller announces the new role at once instead of waiting for the 60 s
 * TOPOLOGY tick (brief §9: "TOPOLOGY 60 s + on child change"). */
static bool update_state(void)
{
    const uint8_t level = siot_link_mesh_level();
    const bool level_changed = level != s_level_seen;
    if (level_changed) {
        s_level_seen = level;
        s_announce_pending = level > 0;
        s_level_change_ms = now_ms();
        siot_survey_set_layer(level == 0 ? 0xFF : level);
        const siot_evt_level_t ev = {.level = level};
        siot_evbus_post(SIOT_EVT_MESH_LEVEL, &ev, sizeof(ev));
        if (level == 0) ESP_LOGI(TAG, "role: not joined (looking for the network)");
        else if (level == 1) ESP_LOGW(TAG, "role: ROOT (level 1) — bridging to the board");
        else ESP_LOGW(TAG, "role: NODE (child, level %u)", level);
    }
    siot_state_t next;
    const bool reachable = board_reachable(now_ms());
    if (level == 0) {
        next = s_state == SIOT_STATE_JOINING ? SIOT_STATE_JOINING : SIOT_STATE_OFFLINE;
    } else if (!reachable) {
        /* A mesh among nodes with no board behind it (lifecycle §6): still
         * "finding the network" for the operator — white solid, not green. */
        next = SIOT_STATE_JOINING;
    } else if (s_comm_fault) {
        next = SIOT_STATE_DEGRADED;
    } else {
        next = SIOT_STATE_ONLINE;
    }
    siot_survey_set_online(next == SIOT_STATE_ONLINE);
    post_state(next);
    return level_changed;
}

/* ---- scheduler ---------------------------------------------------------- */

static void netcore_task(void *arg)
{
    (void)arg;
    int64_t next_hb_ms = 0;
    int64_t next_topo_ms = 2000; /* stagger the first TOPOLOGY */

    for (;;) {
        const int64_t t = now_ms();
        (void)update_state();
        xSemaphoreTake(s_lock, portMAX_DELAY);

        /* Role/layer changed: announce it (HEARTBEAT carries LAYER, TOPOLOGY
         * carries ROLE) as soon as the frames can reach the board — root: the
         * TCP session is up; child: something came down the tree after the
         * change, so the root above us is forwarding. Retried every tick until
         * both frames actually left; then the periodic timers restart. */
        if (s_announce_pending) {
            const uint8_t level = siot_link_mesh_level();
            const bool path_proven = level == 1 ? siot_link_mesh_board_up()
                                   : level >= 2 && s_last_downlink_ms >= s_level_change_ms;
            if (path_proven) {
                emit_heartbeat(t);
                const bool hb_ok = s_last_tx_ok;
                emit_topology(t);
                if (hb_ok && s_last_tx_ok) {
                    s_announce_pending = false;
                    next_hb_ms = t + HB_INTERVAL_MS;
                    next_topo_ms = t + TOPO_INTERVAL_MS;
                    ESP_LOGI(TAG, "role announced (level %u)", level);
                }
            }
        }

        /* NAME_ANNOUNCE once after boot — keep trying until a live transport takes it. */
        if (!s_name_announced && siot_link_mesh_level() > 0 && siot_link_is_up(SIOT_LINK_MESH) &&
            board_reachable(t)) {
            s_name_announced = emit_name_announce();
            if (s_name_announced) ESP_LOGI(TAG, "NAME_ANNOUNCE sent: %s / %s",
                                           siot_config_code()->name, siot_config_code()->zone);
        }
        if (t >= next_hb_ms) { emit_heartbeat(t); next_hb_ms = t + HB_INTERVAL_MS; }
        if (t >= next_topo_ms) { emit_topology(t); next_topo_ms = t + TOPO_INTERVAL_MS; }

        /* Fast phase (spec §9.1): 3 × 2 s, same MSG_ID, fresh MSG_CTR. */
        if (s_pending_used && t >= s_pending_next_ms) {
            if (s_pending_attempts >= RETRY_MAX) {
                s_pending_used = false;
                const siot_evt_ack_t ev = {.msg_id = s_pending_msg_id, .status = SAFR_ACK_ERROR};
                siot_evbus_post(SIOT_EVT_ACK_TIMEOUT, &ev, sizeof(ev));
                if (!s_comm_fault) { /* local TROUBLE COMM_FAULT, not tracked (no recursion) */
                    s_comm_fault = true;
                    ESP_LOGW(TAG, "no ACK after %d tries -> COMM_FAULT", RETRY_MAX);
                    emit_event(t, SAFR_EVT_TROUBLE, SAFR_EC_COMM_FAULT, true, false);
                }
            } else {
                send_uplink(SAFR_MSG_EVENT, s_pending_msg_id, SAFR_F_ACK_REQ, s_pending_payload, SAFR_EVENT_LEN);
                s_pending_attempts++;
                s_pending_next_ms = t + RETRY_BACKOFF_MS;
            }
        }

        /* Re-announce phase (ALARM only, spec §7.2): fresh MSG_ID/CTR, same DEV_SEQ. */
        if (s_alarm_active && t >= s_alarm_next_retx_ms) {
            send_uplink(SAFR_MSG_EVENT, siot_safr_next_msg_id(), SAFR_F_ACK_REQ | SAFR_F_RETX,
                        s_alarm_payload, SAFR_EVENT_LEN);
            s_alarm_next_retx_ms = t + ALARM_RETX_MS;
        }
        xSemaphoreGive(s_lock);
        vTaskDelay(pdMS_TO_TICKS(STEP_MS));
    }
}

esp_err_t siot_netcore_start(void)
{
    if (!siot_config_has_code() || !siot_identity_valid()) return ESP_ERR_INVALID_STATE;
    if (s_lock == NULL) s_lock = xSemaphoreCreateMutex();
    s_epoch_ref_ms = now_ms();

    esp_err_t err;
    if ((err = siot_safr_register(SAFR_MSG_ACK, on_ack, NULL)) != ESP_OK) return err;
    if ((err = siot_safr_register(SAFR_MSG_HEARTBEAT, on_board_heartbeat, NULL)) != ESP_OK) return err;
    if ((err = siot_safr_register(SAFR_MSG_TIME_SYNC, on_time_sync, NULL)) != ESP_OK) return err;
    if ((err = siot_safr_register(SAFR_MSG_COMMAND, on_command, NULL)) != ESP_OK) return err;
    siot_safr_set_tx(tx_sink, NULL);
    siot_link_set_rx(on_link_rx, NULL);
    if ((err = siot_evbus_subscribe(SIOT_EVT_BUTTON_TAP, on_button, NULL, NULL)) != ESP_OK) return err;
    if ((err = siot_evbus_subscribe(SIOT_EVT_BUTTON_DOUBLE_TAP, on_button, NULL, NULL)) != ESP_OK) return err;

    if ((err = siot_link_start(SIOT_LINK_MESH)) != ESP_OK) return err;
    /* Announce the starting state unconditionally: the LED boots assuming
     * SETUP and post_state() skips no-op transitions, so a node that stays
     * JOINING (no board on site) would otherwise blink white forever. */
    s_state = SIOT_STATE_SETUP;
    post_state(SIOT_STATE_JOINING);

    if (xTaskCreatePinnedToCore(netcore_task, "netcore_task", 4096, NULL, 15, &s_task, 1) != pdPASS) {
        return ESP_ERR_NO_MEM;
    }
    return ESP_OK;
}
