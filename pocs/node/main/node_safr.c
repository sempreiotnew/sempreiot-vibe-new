#include "node_safr.h"

#include <string.h>

#include "esp_log.h"
#include "esp_mac.h"
#include "esp_random.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#include "safr_frame.h"
#include "siot_led.h"

#include "node_mesh.h"

static const char *TAG = "node_safr";

/* Bench mode (Talles, 2026-09-18): no spec traffic (HEARTBEAT / TOPOLOGY /
 * NAME_ANNOUNCE compiled out -- set to 0 to restore them, the app needs
 * them to show devices online). Instead, once joined, the node sends the
 * same MANUAL_TEST frame as a TEST-button tap every NODE_BENCH_AUTO_TEST_MS
 * (0 = only on real taps). */
#define NODE_BENCH_BUTTON_ONLY   1
#define NODE_BENCH_AUTO_TEST_MS  10000

#define HB_INTERVAL_MS      15000 /* spec §9.2 nominal powered-device rate */
#define TOPO_INTERVAL_MS     60000
#define ALARM_RETX_MS        60000 /* spec §7.2: re-announce >= every 60s */
#define RETRY_BACKOFF_MS      2000
#define RETRY_MAX                3
#define STEP_MS                250

/* Fallback epoch until TIME_SYNC arrives (same placeholder mesh_sim.c
 * uses -- 2025-07-09 UTC-ish; only matters for display before sync). */
#define DEFAULT_EPOCH 0x686E2Fu

static siot_installation_t s_inst;
static uint8_t   s_mac[6];
static uint16_t  s_boot_ctr;
static uint32_t  s_msg_ctr;
static uint16_t  s_msg_id;
static uint16_t  s_dev_seq;
static uint32_t  s_epoch_base = DEFAULT_EPOCH;
static int64_t   s_epoch_ref_ms;

static bool      s_alarm_active;
static uint8_t   s_alarm_payload[SAFR_EVENT_LEN];
static int64_t   s_alarm_next_retx_ms;

/* One in-flight critical (ALARM) uplink awaiting ACK -- fast phase only
 * (spec §7.2); re-announce phase is handled by s_alarm_active above. */
static bool      s_pending_used;
static uint16_t  s_pending_msg_id;
static uint8_t   s_pending_payload[SAFR_EVENT_LEN];
static uint8_t   s_pending_attempts;
static int64_t   s_pending_next_ms;

static void put_u16(uint8_t *p, uint16_t v) { p[0] = v >> 8; p[1] = v & 0xFF; }
static void put_u32(uint8_t *p, uint32_t v)
{
    p[0] = v >> 24; p[1] = v >> 16; p[2] = v >> 8; p[3] = v & 0xFF;
}

static uint32_t now_epoch(int64_t now_ms)
{
    return s_epoch_base + (uint32_t)((now_ms - s_epoch_ref_ms) / 1000);
}

static bool send_uplink(uint8_t msg_type, uint16_t msg_id, uint8_t flags,
                        const uint8_t *payload, size_t plen)
{
    uint8_t frame[SAFR_MAX_FRAME];
    const uint8_t level = node_mesh_get_level();
    const size_t len = safr_build_frame(
        frame, msg_type, msg_id, s_mac, SAFR_BCAST_MAC,
        (uint8_t)(level < 7 ? 7 - level : 0), level, flags,
        s_boot_ctr, ++s_msg_ctr, payload, plen);
    return len > 0 && node_mesh_send_uplink(frame, len);
}

/* ---- Bench LED (no serial on the board, POC-BRIEF §4.2) ----------------
 * Steady colour = role: white solid while not joined (level 0, still
 * looking for the board's AP or a parent), green blink (1 s) = ROOT (level
 * 1, the one bridging to the board), off = NODE (child, level >= 2). The
 * board itself is the magenta one. Message traffic is signalled by
 * node_mesh (siot_led_comm_blink(): one blue pulse per frame sent or
 * received, role colour off meanwhile). An active ALARM keeps the red base.
 * Every role change is also shouted on the console. */
static const char *role_name(uint8_t level)
{
    return level == 0 ? "NOT JOINED" : level == 1 ? "ROOT" : "NODE";
}

static void update_role_led(void)
{
    static uint8_t s_last_level = 0xFF;

    const uint8_t level = node_mesh_get_level();
    if (level != s_last_level) {
        s_last_level = level;
        if (level >= 2) {
            uint8_t parent[6] = {0};
            int8_t rssi = 0;
            node_mesh_get_parent_info(parent, &rssi);
            ESP_LOGW(TAG, "################################################################");
            ESP_LOGW(TAG, "#  THIS DEVICE IS A NODE (child) -- level %u, parent "
                          "%02x:%02x:%02x:%02x:%02x:%02x rssi %d dBm", level,
                     parent[0], parent[1], parent[2], parent[3], parent[4], parent[5],
                     rssi);
            ESP_LOGW(TAG, "#  LED off = joined under a root; blue pulse = frame sent/received");
            ESP_LOGW(TAG, "################################################################");
        } else if (level == 1) {
            ESP_LOGW(TAG, "================ ROLE: ROOT (level 1) -- bridging to the board, "
                          "LED green blink ================");
        } else {
            ESP_LOGI(TAG, "role: not joined yet, finding the network (LED white)");
        }
    }

    if (s_alarm_active) return; /* red base owned by the alarm path */

    const siot_led_pattern_t want =
        (level == 0) ? SIOT_LED_WHITE_SOLID :
        (level == 1) ? SIOT_LED_GREEN_BLINK : SIOT_LED_OFF;
    if (siot_led_get_base() != want) {
        siot_led_set_pattern(want, 0);
    }
}

static void send_ack(uint16_t acked_msg_id, uint8_t status, const uint8_t dst[6])
{
    uint8_t p[4] = {(uint8_t)(acked_msg_id >> 8), (uint8_t)(acked_msg_id & 0xFF),
                    status, 0x00};
    uint8_t frame[SAFR_MAX_FRAME];
    const uint8_t level = node_mesh_get_level();
    const size_t len = safr_build_frame(
        frame, SAFR_MSG_ACK, ++s_msg_id, s_mac, dst,
        (uint8_t)(level < 7 ? 7 - level : 0), level, 0,
        s_boot_ctr, ++s_msg_ctr, p, sizeof(p));
    if (len > 0) node_mesh_send_uplink(frame, len);
}

/* ---- EVENT (spec §7.1) ---- */

static size_t build_event_payload(uint8_t *p, int64_t now_ms, uint8_t evt_type,
                                  uint8_t evt_code)
{
    p[0] = evt_type;
    p[1] = evt_code;
    put_u32(&p[2], now_epoch(now_ms));
    p[6] = SAFR_PWR_AC_OK | SAFR_PWR_CHARGING; /* AC backbone device, §4.3 */
    p[7] = SAFR_NA_U8;                          /* BATTERY_PCT n/a */
    put_u16(&p[8], SAFR_NA_U16);                 /* SMOKE: no sensor on this bench rig */
    put_u16(&p[10], (uint16_t)SAFR_NA_I16);       /* TEMP n/a */
    p[12] = SAFR_NA_U8;                           /* HUMIDITY n/a */
    p[13] = 0;                                    /* FAULT_FLAGS none */
    p[14] = 0;                                    /* FAULT_CODE none */
    put_u16(&p[15], ++s_dev_seq);
    return SAFR_EVENT_LEN;
}

static void emit_event(int64_t now_ms, uint8_t evt_type, uint8_t evt_code,
                       bool ack_req)
{
    uint8_t payload[SAFR_EVENT_LEN];
    build_event_payload(payload, now_ms, evt_type, evt_code);
    const uint16_t msg_id = ++s_msg_id;
    send_uplink(SAFR_MSG_EVENT, msg_id, ack_req ? SAFR_F_ACK_REQ : 0,
               payload, sizeof(payload));

    if (evt_type == SAFR_EVT_ALARM) {
        s_alarm_active = true;
        memcpy(s_alarm_payload, payload, SAFR_EVENT_LEN);
        s_alarm_next_retx_ms = now_ms + ALARM_RETX_MS;

        s_pending_used = true;
        s_pending_msg_id = msg_id;
        memcpy(s_pending_payload, payload, SAFR_EVENT_LEN);
        s_pending_attempts = 1;
        s_pending_next_ms = now_ms + RETRY_BACKOFF_MS;
    }
}

void node_safr_on_short_press(void)
{
    /* Test button tap -> EVENT ALERT MANUAL_TEST up to the board (via the
     * root when this node is a child, straight over TCP when it is the
     * root). The LED feedback is the send itself: node_mesh fires the blue
     * fast blink when a live transport accepted the frame -- so no blink
     * means the node is not joined and nothing left the device. */
    ESP_LOGW(TAG, ">>> TEST button tapped (%s, level %u) -> MANUAL_TEST to the board",
             role_name(node_mesh_get_level()), node_mesh_get_level());
    emit_event(esp_timer_get_time() / 1000, SAFR_EVT_ALERT,
              SAFR_EC_MANUAL_TEST, true /* POC-BRIEF §4.3: F_ACK_REQ */);
}

void node_safr_on_double_press(void)
{
    ESP_LOGW(TAG, "ALARM: SMOKE_ALARM (double press)");
    emit_event(esp_timer_get_time() / 1000, SAFR_EVT_ALARM,
              SAFR_EC_SMOKE_ALARM, true);
    siot_led_set_pattern(SIOT_LED_RED_SOLID, 0);
}

/* ---- HEARTBEAT (spec §7.3) / TOPOLOGY (spec §7.4) / NAME_ANNOUNCE (§7.11) --- */

static bool s_name_announced;

#if !NODE_BENCH_BUTTON_ONLY
static void emit_heartbeat(int64_t now_ms)
{
    uint8_t p[20];
    put_u32(&p[0], now_epoch(now_ms));
    put_u32(&p[4], (uint32_t)(now_ms / 1000)); /* UPTIME_S */
    p[8] = SAFR_PWR_AC_OK | SAFR_PWR_CHARGING;
    p[9] = SAFR_NA_U8;
    put_u16(&p[10], (uint16_t)SAFR_NA_I16);

    uint8_t parent_mac[6];
    int8_t rssi;
    /* POC-BRIEF §4.3: even for the root, report RSSI/MAC of whatever this
     * node's STA is associated to (the board's AP when root) -- unlike the
     * general spec sentinel for a wired root, this device always has a
     * real wireless hop to report. */
    if (node_mesh_get_parent_info(parent_mac, &rssi)) {
        p[12] = (uint8_t)rssi;
        memcpy(&p[13], parent_mac, 6);
    } else {
        p[12] = (uint8_t)SAFR_NA_RSSI;
        memset(&p[13], 0, 6);
    }
    p[19] = node_mesh_get_level();

    const bool sent = send_uplink(SAFR_MSG_HEARTBEAT, ++s_msg_id, 0, p, sizeof(p));
    ESP_LOGI(TAG, "HEARTBEAT %s (%s, level %u)", sent ? "sent" : "NOT sent",
             role_name(p[19]), p[19]);
}

static void emit_topology(int64_t now_ms)
{
    uint8_t p[SAFR_MAX_PAYLOAD];
    put_u32(&p[0], now_epoch(now_ms));
    p[4] = node_mesh_is_root() ? SAFR_ROLE_ROOT : SAFR_ROLE_NODE;
    p[5] = node_mesh_get_level();

    uint8_t parent_mac[6];
    int8_t rssi;
    if (node_mesh_get_parent_info(parent_mac, &rssi)) {
        memcpy(&p[6], parent_mac, 6);
        p[12] = (uint8_t)rssi;
    } else {
        memset(&p[6], 0, 6);
        p[12] = (uint8_t)SAFR_NA_RSSI;
    }

    uint8_t child_mac[16][6];
    int8_t child_rssi[16];
    const size_t count = node_mesh_get_children(child_mac, child_rssi, 16);
    p[13] = (uint8_t)count;
    size_t off = 14;
    for (size_t i = 0; i < count; i++) {
        memcpy(&p[off], child_mac[i], 6);
        p[off + 6] = (uint8_t)child_rssi[i];
        off += 7;
    }

    send_uplink(SAFR_MSG_TOPOLOGY, ++s_msg_id, 0, p, off);
}

static bool emit_name_announce(void)
{
    uint8_t p[1 + 32 + 1 + 16];
    const uint8_t name_len = (uint8_t)strnlen(s_inst.name, 32);
    const uint8_t zone_len = (uint8_t)strnlen(s_inst.zone, 16);
    size_t off = 0;
    p[off++] = name_len;
    memcpy(&p[off], s_inst.name, name_len); off += name_len;
    p[off++] = zone_len;
    memcpy(&p[off], s_inst.zone, zone_len); off += zone_len;
    return send_uplink(SAFR_MSG_NAME_ANNOUNCE, ++s_msg_id, 0, p, off);
}
#endif /* !NODE_BENCH_BUTTON_ONLY */

/* ---- downlink (from node_mesh, already dedup'd) ---- */

static void handle_command(const safr_rx_frame_t *rx)
{
    if (rx->payload_len < 2) return;
    const uint8_t cmd = rx->payload[0];

    switch (cmd) {
    case SAFR_CMD_LINK_CHECK:
        break; /* board-level downlink supervision no-op (spec §9.3) */
    case SAFR_CMD_IDENTIFY: {
        const uint8_t seconds = rx->payload_len >= 3 ? rx->payload[2] : 3;
        siot_led_set_pattern(SIOT_LED_BLUE_BLINK, (uint32_t)seconds * 1000);
        break;
    }
    case SAFR_CMD_TEST:
        emit_event(esp_timer_get_time() / 1000, SAFR_EVT_ALERT,
                  SAFR_EC_MANUAL_TEST, true);
        break;
    case SAFR_CMD_RESET:
        s_alarm_active = false;
        s_pending_used = false;
        siot_led_set_pattern(SIOT_LED_WHITE_SOLID, 0); /* update_role_led()
                                            * switches to green on its next
                                            * pass now that the alarm is off */
        break;
    case SAFR_CMD_SILENCE:
    case SAFR_CMD_RELAY_SET:
    default:
        break; /* no sounder/relay hardware in this POC (round 1 scope) */
    }
    send_ack(rx->msg_id, SAFR_ACK_OK, rx->src_mac);
}

static void node_safr_handle_downlink(const uint8_t *frame, size_t len)
{
    safr_rx_frame_t rx;
    if (!safr_parse_frame(frame, len, &rx)) return;

    const bool for_me = memcmp(rx.dst_mac, s_mac, 6) == 0 ||
                        memcmp(rx.dst_mac, SAFR_BCAST_MAC, 6) == 0;
    if (!for_me) return;

    switch (rx.msg_type) {
    case SAFR_MSG_ACK:
        if (rx.payload_len >= 4) {
            const uint16_t acked = ((uint16_t)rx.payload[0] << 8) | rx.payload[1];
            if (s_pending_used && s_pending_msg_id == acked) s_pending_used = false;
        }
        break;
    case SAFR_MSG_TIME_SYNC:
        if (rx.payload_len >= 5) {
            s_epoch_base = ((uint32_t)rx.payload[0] << 24) |
                           ((uint32_t)rx.payload[1] << 16) |
                           ((uint32_t)rx.payload[2] << 8) | rx.payload[3];
            s_epoch_ref_ms = esp_timer_get_time() / 1000;
            send_ack(rx.msg_id, SAFR_ACK_OK, rx.src_mac);
        }
        break;
    case SAFR_MSG_COMMAND:
        handle_command(&rx);
        break;
    default:
        break; /* EVENT_LOG_REQ etc. are board/root-only concerns */
    }
}

/* ---- scheduler ---- */

static void safr_task(void *arg)
{
    int64_t next_hb_ms = 0;
    int64_t next_topo_ms = 2000; /* stagger first TOPOLOGY slightly */

    for (;;) {
        const int64_t now_ms = esp_timer_get_time() / 1000;

        update_role_led();

        /* Spec §7.11: NAME_ANNOUNCE once after boot -- but "after boot" the
         * mesh is usually not up yet (the very first attempt used to fail
         * with "raw send ... ESP_FAIL" while the STA was still associating,
         * and the name never reached the board). Keep trying until a live
         * transport accepts it, then stop. */
#if !NODE_BENCH_BUTTON_ONLY
        if (!s_name_announced && node_mesh_get_level() > 0) {
            s_name_announced = emit_name_announce();
            if (s_name_announced) ESP_LOGI(TAG, "NAME_ANNOUNCE sent: %s / %s",
                                           s_inst.name, s_inst.zone);
        }

        if (now_ms >= next_hb_ms) {
            emit_heartbeat(now_ms);
            next_hb_ms = now_ms + HB_INTERVAL_MS;
        }
        if (now_ms >= next_topo_ms) {
            emit_topology(now_ms);
            next_topo_ms = now_ms + TOPO_INTERVAL_MS;
        }
#else
        (void)next_hb_ms; (void)next_topo_ms;
#if NODE_BENCH_AUTO_TEST_MS > 0
        /* Bench: pretend the TEST button was tapped every 10 s (once
         * joined), so the LEDs show traffic without anyone at the bench. */
        static int64_t s_next_auto_test_ms = 0;
        if (node_mesh_get_level() > 0 && now_ms >= s_next_auto_test_ms) {
            s_next_auto_test_ms = now_ms + NODE_BENCH_AUTO_TEST_MS;
            ESP_LOGW(TAG, ">>> auto TEST (every %d s, %s, level %u) -> MANUAL_TEST to the board",
                     NODE_BENCH_AUTO_TEST_MS / 1000, role_name(node_mesh_get_level()),
                     node_mesh_get_level());
            emit_event(now_ms, SAFR_EVT_ALERT, SAFR_EC_MANUAL_TEST, true);
        }
#endif
#endif

        /* Fast phase (spec §7.2): 3 x 2s, same MSG_ID, fresh MSG_CTR. */
        if (s_pending_used && now_ms >= s_pending_next_ms) {
            if (s_pending_attempts >= RETRY_MAX) {
                s_pending_used = false; /* fast phase over, not a give-up:
                                         * alarm re-announce below persists */
            } else {
                send_uplink(SAFR_MSG_EVENT, s_pending_msg_id, SAFR_F_ACK_REQ,
                           s_pending_payload, SAFR_EVENT_LEN);
                s_pending_attempts++;
                s_pending_next_ms = now_ms + RETRY_BACKOFF_MS;
            }
        }

        /* Re-announcement phase (ALARM only, spec §7.2): fresh MSG_ID/CTR,
         * same DEV_SEQ (payload unchanged), F_RETX, until RESET. */
        if (s_alarm_active && now_ms >= s_alarm_next_retx_ms) {
            send_uplink(SAFR_MSG_EVENT, ++s_msg_id,
                       SAFR_F_ACK_REQ | SAFR_F_RETX,
                       s_alarm_payload, SAFR_EVENT_LEN);
            s_alarm_next_retx_ms = now_ms + ALARM_RETX_MS;
        }

        vTaskDelay(pdMS_TO_TICKS(STEP_MS));
    }
}

void node_safr_start(const siot_installation_t *inst)
{
    s_inst = *inst;
    esp_read_mac(s_mac, ESP_MAC_WIFI_STA);
    s_boot_ctr = (uint16_t)(1 + (esp_random() % 0xFFFE)); /* never 0 */
    s_msg_ctr = 0;
    s_msg_id = 0;
    s_dev_seq = (uint16_t)(esp_random() % 0xF000);
    s_epoch_ref_ms = esp_timer_get_time() / 1000;

    node_mesh_set_downlink_handler(node_safr_handle_downlink);
    s_name_announced = false; /* sent from safr_task once joined (spec §7.11) */

    xTaskCreate(safr_task, "node_safr", 4096, NULL, 9, NULL);
}
