#include "mesh_sim.h"

#include <string.h>

#include "esp_random.h"

/* ── Simulation tuning ─────────────────────────────────────────── */

#define NODE_COUNT        8
/* Test-accelerated schedules: every node reports every 5 s so the app fills
 * up fast on the bench. Production devices follow the spec's nominal rates
 * (15 s powered / 60 s leaf — docs/safr/protocol-safr-v3.md §9.2). */
#define HB_POWERED_MS     5000
#define HB_LEAF_MS        5000
#define TOPO_MS           20000
#define SCEN_MIN_GAP_MS   60000
#define SCEN_MAX_GAP_MS   180000
#define ALERT_STEP_MS     3000
#define ALERT_STEPS       5
/* Alarm re-announcement (spec §7.2 — NFPA 72: repeat ≤60 s until restore or
 * RESET). Bench-accelerated to 15 s; production uses ≤60 s. */
#define ALARM_RETX_MS     15000
/* The simulated smoke clears on its own after 3 min if nobody RESETs. */
#define ALARM_AUTO_CLEAR_MS 180000
#define RETRY_BACKOFF_MS  2000
#define RETRY_MAX         3
#define PENDING_MAX       8
/* Root event journal (spec §8 — EN 54-25 "no alarm lost"). RAM ring on the
 * mock; real hardware persists this in flash. */
#define JOURNAL_CAP       64

/* Fallback epoch until the central sends TIME_SYNC (2025-07-09 UTC-ish) */
#define DEFAULT_EPOCH     0x686E2F00u

typedef enum {
    SCEN_NONE = 0,
    SCEN_TROUBLE,
    SCEN_ALERT_RAMP,
    SCEN_ALARM,
} scen_t;

typedef struct {
    uint8_t  mac[6];
    uint8_t  role;       /* SAFR_ROLE_* */
    uint8_t  layer;
    int8_t   parent;     /* node index, -1 = the central */
    uint16_t boot_ctr;
    uint32_t msg_ctr;
    uint16_t msg_id;
    uint16_t dev_seq;    /* event identity (spec §6) — NVS on real hw */
    uint8_t  battery_pct;
    int8_t   rssi_base;
    int64_t  next_hb_ms;
    int64_t  next_topo_ms;
    /* scenario state */
    scen_t   scen;
    uint8_t  scen_code;      /* EVENT_CODE driving the scenario */
    int64_t  scen_next_ms;   /* next scenario step (ramp/restore) */
    uint8_t  ramp_step;
    uint16_t smoke;
    bool     relay_on;
    /* active-alarm re-announcement (spec §7.2): same payload + DEV_SEQ,
     * fresh MSG_ID, F_RETX, every ALARM_RETX_MS until restore/RESET */
    bool     alarm_active;
    uint8_t  alarm_payload[SAFR_EVENT_LEN];
    int64_t  alarm_next_retx_ms;
    int64_t  alarm_clear_ms;
} sim_node_t;

/* Critical uplink awaiting the central's ACK (root retries, spec §7) */
typedef struct {
    bool     used;
    uint8_t  node;       /* origin node index */
    uint16_t msg_id;     /* reused on retransmit */
    uint8_t  payload[SAFR_MAX_PAYLOAD];
    size_t   payload_len;
    uint8_t  attempts;
    int64_t  next_ms;
} pending_t;

/* Root journal entry (spec §8): the original event, replayable bit-for-bit */
typedef struct {
    uint32_t jrn_seq;
    uint8_t  mac[6];
    uint8_t  payload[SAFR_EVENT_LEN];
} journal_t;

static sim_node_t s_nodes[NODE_COUNT];
static pending_t  s_pending[PENDING_MAX];
static journal_t  s_journal[JOURNAL_CAP];
static uint32_t   s_jrn_top;        /* highest assigned JRN_SEQ (0 = none) */
static int64_t    s_next_scen_ms;
static uint32_t   s_epoch_base = DEFAULT_EPOCH;
static int64_t    s_epoch_ref_ms;   /* uptime when s_epoch_base was set */

static uint32_t randu(uint32_t lo, uint32_t hi)
{
    return lo + (esp_random() % (hi - lo + 1));
}

static uint32_t now_epoch(int64_t now_ms)
{
    return s_epoch_base + (uint32_t)((now_ms - s_epoch_ref_ms) / 1000);
}

static void put_u16(uint8_t *p, uint16_t v) { p[0] = v >> 8; p[1] = v & 0xFF; }
static void put_u32(uint8_t *p, uint32_t v)
{
    p[0] = v >> 24; p[1] = v >> 16; p[2] = v >> 8; p[3] = v & 0xFF;
}

static int8_t jitter_rssi(const sim_node_t *n)
{
    return (int8_t)(n->rssi_base + (int)randu(0, 8) - 4);
}

static uint8_t pwr_flags(const sim_node_t *n)
{
    return n->role == SAFR_ROLE_LEAF
               ? SAFR_PWR_ON_BATTERY
               : (SAFR_PWR_AC_OK | SAFR_PWR_CHARGING);
}

static const uint8_t *parent_mac(const sim_node_t *n)
{
    return n->parent < 0 ? SAFR_CENTRAL_MAC : s_nodes[n->parent].mac;
}

/* ── Frame emission ────────────────────────────────────────────── */

static void send_from_node(sim_node_t *n, uint8_t msg_type, uint16_t msg_id,
                           uint8_t extra_flags,
                           const uint8_t *payload, size_t plen)
{
    uint8_t frame[SAFR_MAX_FRAME];
    size_t len = safr_build_frame(
        frame, msg_type, msg_id, n->mac, SAFR_BCAST_MAC,
        (uint8_t)(7 - n->layer), n->layer, extra_flags,
        n->boot_ctr, ++n->msg_ctr, payload, plen);
    if (len > 0) safr_link_send(frame, len);
}

static void queue_critical(uint8_t node_idx, uint16_t msg_id,
                           const uint8_t *payload, size_t plen,
                           int64_t now_ms)
{
    for (int i = 0; i < PENDING_MAX; i++) {
        if (s_pending[i].used) continue;
        s_pending[i] = (pending_t){
            .used = true,
            .node = node_idx,
            .msg_id = msg_id,
            .payload_len = plen,
            .attempts = 1,
            .next_ms = now_ms + RETRY_BACKOFF_MS,
        };
        memcpy(s_pending[i].payload, payload, plen);
        return;
    }
}

static size_t build_event_payload(uint8_t *p, sim_node_t *n, int64_t now_ms,
                                  uint8_t evt_type, uint8_t evt_code,
                                  uint16_t smoke, uint8_t fault_flags,
                                  uint8_t fault_code)
{
    p[0] = evt_type;
    p[1] = evt_code;
    put_u32(&p[2], now_epoch(now_ms));
    p[6] = pwr_flags(n);
    p[7] = n->battery_pct;
    put_u16(&p[8], smoke);
    put_u16(&p[10], (uint16_t)(int16_t)randu(180, 350)); /* 18.0–35.0 °C */
    p[12] = (uint8_t)randu(30, 70);
    p[13] = fault_flags;
    p[14] = fault_code;
    put_u16(&p[15], ++n->dev_seq); /* event identity (spec §6) */
    return SAFR_EVENT_LEN;
}

/* Root journal (spec §8): every distinct event is appended once — the 60 s
 * re-announcements reuse the entry instead of duplicating it. */
static void journal_append(const uint8_t mac[6],
                           const uint8_t payload[SAFR_EVENT_LEN])
{
    journal_t *j = &s_journal[s_jrn_top % JOURNAL_CAP];
    j->jrn_seq = ++s_jrn_top;
    memcpy(j->mac, mac, 6);
    memcpy(j->payload, payload, SAFR_EVENT_LEN);
}

static void emit_event(uint8_t node_idx, int64_t now_ms, uint8_t evt_type,
                       uint8_t evt_code, uint16_t smoke, uint8_t fault_flags,
                       uint8_t fault_code)
{
    sim_node_t *n = &s_nodes[node_idx];
    uint8_t payload[SAFR_EVENT_LEN];
    build_event_payload(payload, n, now_ms, evt_type, evt_code, smoke,
                        fault_flags, fault_code);
    journal_append(n->mac, payload);

    const bool critical =
        evt_type == SAFR_EVT_ALARM || evt_type == SAFR_EVT_TROUBLE;
    const uint16_t msg_id = ++n->msg_id;

    send_from_node(n, SAFR_MSG_EVENT, msg_id,
                   critical ? SAFR_F_ACK_REQ : 0, payload, sizeof(payload));
    if (critical) {
        queue_critical(node_idx, msg_id, payload, sizeof(payload), now_ms);
    }

    /* Spec §7.2: an ALARM keeps re-announcing until restore or RESET —
     * store the exact payload so DEV_SEQ stays constant across repeats. */
    if (evt_type == SAFR_EVT_ALARM) {
        n->alarm_active = true;
        memcpy(n->alarm_payload, payload, SAFR_EVENT_LEN);
        n->alarm_next_retx_ms = now_ms + ALARM_RETX_MS;
        n->alarm_clear_ms = now_ms + ALARM_AUTO_CLEAR_MS;
    } else if (evt_type == SAFR_EVT_OK) {
        n->alarm_active = false;
    }
}

/* Re-announce an active alarm: same DEV_SEQ (dedupe key), fresh MSG_ID and
 * MSG_CTR, F_RETX so the console labels it honestly (spec §7.2). */
static void alarm_retx_step(sim_node_t *n, int64_t now_ms)
{
    if (!n->alarm_active || now_ms < n->alarm_next_retx_ms) return;
    send_from_node(n, SAFR_MSG_EVENT, ++n->msg_id,
                   SAFR_F_ACK_REQ | SAFR_F_RETX,
                   n->alarm_payload, SAFR_EVENT_LEN);
    n->alarm_next_retx_ms = now_ms + ALARM_RETX_MS;
}

static void emit_heartbeat(sim_node_t *n, int64_t now_ms)
{
    uint8_t p[20];
    put_u32(&p[0], now_epoch(now_ms));
    put_u32(&p[4], (uint32_t)(now_ms / 1000));
    p[8] = pwr_flags(n);
    p[9] = n->battery_pct;
    put_u16(&p[10], (uint16_t)(int16_t)randu(180, 350));
    p[12] = n->parent < 0 ? (uint8_t)SAFR_NA_RSSI : (uint8_t)jitter_rssi(n);
    memcpy(&p[13], parent_mac(n), 6);
    p[19] = n->layer;
    send_from_node(n, SAFR_MSG_HEARTBEAT, ++n->msg_id, 0, p, sizeof(p));
}

static void emit_topology(sim_node_t *n, int64_t now_ms)
{
    uint8_t p[SAFR_MAX_PAYLOAD];
    put_u32(&p[0], now_epoch(now_ms));
    p[4] = n->role;
    p[5] = n->layer;
    memcpy(&p[6], parent_mac(n), 6);
    p[12] = n->parent < 0 ? (uint8_t)SAFR_NA_RSSI : (uint8_t)jitter_rssi(n);

    size_t off = 14;
    uint8_t count = 0;
    const int self = (int)(n - s_nodes);
    for (int i = 0; i < NODE_COUNT; i++) {
        if (s_nodes[i].parent != self) continue;
        memcpy(&p[off], s_nodes[i].mac, 6);
        p[off + 6] = (uint8_t)jitter_rssi(&s_nodes[i]);
        off += 7;
        count++;
    }
    p[13] = count;
    send_from_node(n, SAFR_MSG_TOPOLOGY, ++n->msg_id, 0, p, off);
}

/* ── Scenario engine ───────────────────────────────────────────── */

static void scenario_start(int64_t now_ms)
{
    const uint32_t roll = randu(1, 100);
    if (roll <= 70) return; /* nothing this round */

    sim_node_t *n = &s_nodes[randu(1, NODE_COUNT - 1)]; /* never the root */
    if (n->scen != SCEN_NONE) return;
    const uint8_t idx = (uint8_t)(n - s_nodes);

    if (roll <= 85) {
        /* TROUBLE with auto-restore */
        static const uint8_t codes[] = {SAFR_EC_BATT_LOW, SAFR_EC_TAMPER,
                                        SAFR_EC_SENSOR_FAULT};
        n->scen = SCEN_TROUBLE;
        n->scen_code = codes[randu(0, 2)];
        n->scen_next_ms = now_ms + randu(30000, 60000);
        uint8_t ff = n->scen_code == SAFR_EC_SENSOR_FAULT ? SAFR_FLT_SMOKE_SENSOR
                     : n->scen_code == SAFR_EC_BATT_LOW   ? SAFR_FLT_BATT_CRIT
                                                          : 0;
        emit_event(idx, now_ms, SAFR_EVT_TROUBLE, n->scen_code,
                   n->smoke, ff, n->scen_code);
    } else {
        /* ALERT smoke ramp; 1 in 3 ramps escalates to ALARM */
        n->scen = SCEN_ALERT_RAMP;
        n->scen_code = randu(1, 3) == 1 ? SAFR_EC_SMOKE_ALARM : SAFR_EC_SMOKE_RISING;
        n->ramp_step = 0;
        n->scen_next_ms = now_ms; /* first step immediately */
    }
}

static void scenario_step(sim_node_t *n, int64_t now_ms)
{
    const uint8_t idx = (uint8_t)(n - s_nodes);
    if (n->scen == SCEN_NONE || now_ms < n->scen_next_ms) return;

    switch (n->scen) {
    case SCEN_TROUBLE:
        emit_event(idx, now_ms, SAFR_EVT_OK, SAFR_EC_RESTORE,
                   n->smoke, 0, n->scen_code);
        n->scen = SCEN_NONE;
        break;

    case SCEN_ALERT_RAMP:
        n->ramp_step++;
        n->smoke = (uint16_t)(600 + n->ramp_step * 700 + randu(0, 200));
        if (n->ramp_step < ALERT_STEPS) {
            emit_event(idx, now_ms, SAFR_EVT_ALERT, SAFR_EC_SMOKE_RISING,
                       n->smoke, 0, 0);
            n->scen_next_ms = now_ms + ALERT_STEP_MS;
        } else if (n->scen_code == SAFR_EC_SMOKE_ALARM) {
            n->scen = SCEN_ALARM;
            emit_event(idx, now_ms, SAFR_EVT_ALARM, SAFR_EC_SMOKE_ALARM,
                       n->smoke, 0, 0);
            n->scen_next_ms = now_ms + ALARM_AUTO_CLEAR_MS;
        } else {
            emit_event(idx, now_ms, SAFR_EVT_OK, SAFR_EC_RESTORE,
                       300, 0, SAFR_EC_SMOKE_RISING);
            n->smoke = 300;
            n->scen = SCEN_NONE;
        }
        break;

    case SCEN_ALARM:
        /* The simulated smoke finally clears (or a RESET arrived and pulled
         * scen_next_ms forward). RESTORE ends the re-announcement loop but
         * the CENTRAL keeps its latch until the operator RESET (§7.1.4). */
        emit_event(idx, now_ms, SAFR_EVT_OK, SAFR_EC_RESTORE,
                   300, 0, SAFR_EC_SMOKE_ALARM);
        n->smoke = 300;
        n->scen = SCEN_NONE;
        break;

    default:
        n->scen = SCEN_NONE;
        break;
    }
}

/* ── Root behavior: retries + downlink handling ────────────────── */

static void retries_step(int64_t now_ms)
{
    for (int i = 0; i < PENDING_MAX; i++) {
        pending_t *pd = &s_pending[i];
        if (!pd->used || now_ms < pd->next_ms) continue;
        if (pd->attempts >= RETRY_MAX) {
            /* Fast phase over (spec §7.2). NOT a give-up: an active ALARM
             * keeps re-announcing via alarm_retx_step until restore/RESET,
             * and the event sits in the journal for backfill. */
            pd->used = false;
            continue;
        }
        /* Same MSG_ID (receiver dedupes), fresh MSG_CTR (nonce never reused) */
        sim_node_t *n = &s_nodes[pd->node];
        send_from_node(n, SAFR_MSG_EVENT, pd->msg_id, SAFR_F_ACK_REQ,
                       pd->payload, pd->payload_len);
        pd->attempts++;
        pd->next_ms = now_ms + RETRY_BACKOFF_MS;
    }
}

static void root_send_ack(uint16_t acked_msg_id, uint8_t status,
                          const uint8_t dst[6])
{
    sim_node_t *root = &s_nodes[0];
    uint8_t p[4] = {(uint8_t)(acked_msg_id >> 8), (uint8_t)(acked_msg_id & 0xFF),
                    status, 0x00};
    uint8_t frame[SAFR_MAX_FRAME];
    size_t len = safr_build_frame(
        frame, SAFR_MSG_ACK, ++root->msg_id, root->mac, dst,
        7, 0, 0, root->boot_ctr, ++root->msg_ctr, p, sizeof(p));
    if (len > 0) safr_link_send(frame, len);
}

static int find_node_by_mac(const uint8_t mac[6])
{
    for (int i = 0; i < NODE_COUNT; i++) {
        if (memcmp(s_nodes[i].mac, mac, 6) == 0) return i;
    }
    return -1;
}

/* EVENT_LOG_REQ → replay journal entries newer than since_seq as
 * EVENT_LOG_DATA (spec §7.8/§7.9). Answers EMPTY (with our current top) when
 * nothing newer exists, so the central can detect a journal reset. */
static void root_send_journal(uint32_t since_seq, uint8_t max_count,
                              const uint8_t dst[6])
{
    sim_node_t *root = &s_nodes[0];
    if (max_count == 0 || max_count > SAFR_LOG_BATCH_DEF) {
        max_count = SAFR_LOG_BATCH_DEF;
    }

    /* Oldest entry still held (ring buffer may have overwritten history) */
    const uint32_t oldest =
        s_jrn_top > JOURNAL_CAP ? s_jrn_top - JOURNAL_CAP + 1 : 1;
    uint32_t seq = since_seq + 1 < oldest ? oldest : since_seq + 1;

    uint8_t p[SAFR_LOG_DATA_LEN];
    uint8_t frame[SAFR_MAX_FRAME];

    if (seq > s_jrn_top) { /* nothing newer */
        memset(p, 0, sizeof(p));
        put_u32(&p[0], s_jrn_top);
        p[4] = SAFR_LOG_F_LAST | SAFR_LOG_F_EMPTY;
        size_t len = safr_build_frame(
            frame, SAFR_MSG_EVENT_LOG_DATA, ++root->msg_id, root->mac, dst,
            7, 0, 0, root->boot_ctr, ++root->msg_ctr, p, sizeof(p));
        if (len > 0) safr_link_send(frame, len);
        return;
    }

    for (uint8_t sent = 0; seq <= s_jrn_top && sent < max_count; seq++, sent++) {
        const journal_t *j = &s_journal[(seq - 1) % JOURNAL_CAP];
        put_u32(&p[0], j->jrn_seq);
        p[4] = (seq == s_jrn_top || sent == max_count - 1) ? SAFR_LOG_F_LAST : 0;
        memcpy(&p[5], j->mac, 6);
        memcpy(&p[11], j->payload, SAFR_EVENT_LEN);
        size_t len = safr_build_frame(
            frame, SAFR_MSG_EVENT_LOG_DATA, ++root->msg_id, root->mac, dst,
            7, 0, 0, root->boot_ctr, ++root->msg_ctr, p, sizeof(p));
        if (len > 0) safr_link_send(frame, len);
    }
}

void mesh_sim_handle_rx(const safr_rx_frame_t *rx, int64_t now_ms)
{
    switch (rx->msg_type) {
    case SAFR_MSG_ACK:
        if (rx->payload_len >= 4) {
            const uint16_t acked = ((uint16_t)rx->payload[0] << 8) | rx->payload[1];
            for (int i = 0; i < PENDING_MAX; i++) {
                if (s_pending[i].used && s_pending[i].msg_id == acked) {
                    s_pending[i].used = false;
                }
            }
        }
        break;

    case SAFR_MSG_TIME_SYNC:
        if (rx->payload_len >= 5) {
            s_epoch_base = ((uint32_t)rx->payload[0] << 24) |
                           ((uint32_t)rx->payload[1] << 16) |
                           ((uint32_t)rx->payload[2] << 8) | rx->payload[3];
            s_epoch_ref_ms = now_ms;
            root_send_ack(rx->msg_id, SAFR_ACK_OK, rx->src_mac);
        }
        break;

    case SAFR_MSG_COMMAND: {
        if (rx->payload_len < 2) break;
        const uint8_t cmd = rx->payload[0];

        /* LINK_CHECK (spec §9.3): downlink supervision no-op — the ACK
         * itself is the proof the central→root path works. */
        if (cmd == SAFR_CMD_LINK_CHECK) {
            root_send_ack(rx->msg_id, SAFR_ACK_OK, rx->src_mac);
            break;
        }

        const bool bcast = memcmp(rx->dst_mac, SAFR_BCAST_MAC, 6) == 0;
        const int target = bcast ? -1 : find_node_by_mac(rx->dst_mac);
        if (!bcast && target < 0) {
            root_send_ack(rx->msg_id, SAFR_ACK_UNKNOWN_DST, rx->src_mac);
            break;
        }
        for (int i = 0; i < NODE_COUNT; i++) {
            if (!bcast && i != target) continue;
            sim_node_t *n = &s_nodes[i];
            switch (cmd) {
            case SAFR_CMD_SILENCE:
                /* Silences sounders only — the alarm condition, the
                 * re-announcements and the central latch all persist
                 * (UL 864: silence ≠ reset). */
                break;
            case SAFR_CMD_RESET:
                /* Operator reset (spec §7.1.4): device leaves alarm state —
                 * the simulated smoke condition clears on the next step. */
                if (n->scen == SCEN_ALARM || n->scen == SCEN_ALERT_RAMP) {
                    n->scen = SCEN_ALARM;
                    n->scen_next_ms = now_ms; /* RESTORE on next step */
                }
                n->alarm_active = false;
                break;
            case SAFR_CMD_RELAY_SET:
                if (rx->payload_len >= 3) n->relay_on = rx->payload[2] != 0;
                break;
            case SAFR_CMD_TEST:
                emit_event((uint8_t)i, now_ms, SAFR_EVT_ALERT,
                           SAFR_EC_MANUAL_TEST, n->smoke, 0, 0);
                break;
            case SAFR_CMD_IDENTIFY:
            default:
                break; /* visual-only on real hardware */
            }
        }
        root_send_ack(rx->msg_id, SAFR_ACK_OK, rx->src_mac);
        break;
    }

    case SAFR_MSG_EVENT_LOG_REQ:
        if (rx->payload_len >= 5) {
            const uint32_t since = ((uint32_t)rx->payload[0] << 24) |
                                   ((uint32_t)rx->payload[1] << 16) |
                                   ((uint32_t)rx->payload[2] << 8) |
                                   rx->payload[3];
            root_send_journal(since, rx->payload[4], rx->src_mac);
        }
        break;

    default:
        break;
    }
}

/* ── Setup & main step ─────────────────────────────────────────── */

static void node_init(int i, uint8_t role, uint8_t layer, int8_t parent,
                      int8_t rssi_base)
{
    sim_node_t *n = &s_nodes[i];
    memset(n, 0, sizeof(*n));
    n->mac[0] = 0x5A; n->mac[1] = 0x46; n->mac[2] = 0x52;
    n->mac[5] = (uint8_t)(i + 1);
    n->role = role;
    n->layer = layer;
    n->parent = parent;
    n->boot_ctr = (uint16_t)randu(2, 0xFFFE); /* never 1: reserved for vectors */
    /* Random start simulates the NVS-persisted counter and avoids colliding
     * with the boot vectors' DEV_SEQ 1 (the central dedupes on it). */
    n->dev_seq = (uint16_t)randu(0x0010, 0xF000);
    n->battery_pct = role == SAFR_ROLE_LEAF ? (uint8_t)randu(60, 100) : 100;
    n->rssi_base = rssi_base;
    n->smoke = 300;
    /* Staggered schedules so frames don't burst together */
    const int64_t hb = role == SAFR_ROLE_LEAF ? HB_LEAF_MS : HB_POWERED_MS;
    n->next_hb_ms = 2000 + i * 1300;
    n->next_topo_ms = 4000 + i * 900;
    (void)hb;
}

void mesh_sim_init(void)
{
    /*            role             layer parent rssi */
    node_init(0, SAFR_ROLE_ROOT,   0,    -1,    -40);
    node_init(1, SAFR_ROLE_NODE,   1,     0,    -58);
    node_init(2, SAFR_ROLE_NODE,   1,     0,    -63);
    node_init(3, SAFR_ROLE_LEAF,   2,     1,    -71);
    node_init(4, SAFR_ROLE_LEAF,   2,     2,    -68);
    node_init(5, SAFR_ROLE_LEAF,   2,     1,    -80);
    node_init(6, SAFR_ROLE_LEAF,   2,     2,    -75);
    node_init(7, SAFR_ROLE_LEAF,   2,     1,    -84);
    memset(s_pending, 0, sizeof(s_pending));
    memset(s_journal, 0, sizeof(s_journal));
    s_jrn_top = 0;
    s_next_scen_ms = SCEN_MIN_GAP_MS;
    s_epoch_ref_ms = 0;
}

void mesh_sim_emit_boot_vectors(void)
{
    /* Deterministic Appendix-A vectors: SRC = root MAC, BOOT_CTR = 1,
     * MSG_ID/MSG_CTR = 1..3, FLAGS = F_ENC only. Bytes must equal the
     * goldens in the spec and in safr_v3_vectors_test.dart. */
    static const uint8_t v1[] = {
        0x03, 0x01, 0x68, 0x6E, 0x2F, 0x00, 0x05, 0x55,
        0x10, 0x68, 0x02, 0x26, 0x2A, 0x00, 0x00, 0x00, 0x01,
    };
    static const uint8_t v2[] = {
        0x68, 0x6E, 0x2F, 0x01, 0x00, 0x00, 0x0E, 0x10,
        0x01, 0x64, 0x00, 0xFA, 0x7F, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x01, 0x00,
    };
    static const uint8_t v3[] = {
        0x68, 0x6E, 0x2F, 0x02, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x01, 0x7F, 0x02,
        0x5A, 0x46, 0x52, 0x00, 0x00, 0x02, 0xBE,
        0x5A, 0x46, 0x52, 0x00, 0x00, 0x03, 0xC4,
    };
    const struct { uint8_t type; const uint8_t *p; size_t len; } vecs[] = {
        {SAFR_MSG_EVENT, v1, sizeof(v1)},
        {SAFR_MSG_HEARTBEAT, v2, sizeof(v2)},
        {SAFR_MSG_TOPOLOGY, v3, sizeof(v3)},
    };

    uint8_t frame[SAFR_MAX_FRAME];
    for (uint16_t i = 0; i < 3; i++) {
        size_t len = safr_build_frame(
            frame, vecs[i].type, (uint16_t)(i + 1), s_nodes[0].mac,
            SAFR_BCAST_MAC, 7, 0, 0, 0x0001, (uint32_t)(i + 1),
            vecs[i].p, vecs[i].len);
        if (len > 0) safr_link_send(frame, len);
    }
}

void mesh_sim_step(int64_t now_ms)
{
    for (int i = 0; i < NODE_COUNT; i++) {
        sim_node_t *n = &s_nodes[i];
        const int64_t hb_int =
            n->role == SAFR_ROLE_LEAF ? HB_LEAF_MS : HB_POWERED_MS;

        if (now_ms >= n->next_hb_ms) {
            emit_heartbeat(n, now_ms);
            n->next_hb_ms = now_ms + hb_int;
            /* Slow battery drain on leaves */
            if (n->role == SAFR_ROLE_LEAF && n->battery_pct > 20 &&
                randu(1, 10) == 1) {
                n->battery_pct--;
            }
        }
        if (n->role != SAFR_ROLE_LEAF && now_ms >= n->next_topo_ms) {
            emit_topology(n, now_ms);
            n->next_topo_ms = now_ms + TOPO_MS;
        }
        scenario_step(n, now_ms);
        alarm_retx_step(n, now_ms);
    }

    if (now_ms >= s_next_scen_ms) {
        scenario_start(now_ms);
        s_next_scen_ms = now_ms + randu(SCEN_MIN_GAP_MS, SCEN_MAX_GAP_MS);
    }

    retries_step(now_ms);
}
