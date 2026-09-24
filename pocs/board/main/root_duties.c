#include "root_duties.h"

#include <string.h>

#include "esp_random.h"
#include "esp_timer.h"

#include "installation_msg.h"
#include "serial_link.h"
#include "tcp_link.h"

#define HEARTBEAT_INTERVAL_MS 15000
#define TOPOLOGY_INTERVAL_MS  60000
#define CHILD_TIMEOUT_MS      180000 /* stale entries just stop being reported; no eviction needed for round 1 */

static void put_u16(uint8_t *p, uint16_t v) { p[0] = (uint8_t)(v >> 8); p[1] = (uint8_t)(v & 0xFF); }
static void put_u32(uint8_t *p, uint32_t v)
{
    p[0] = (uint8_t)(v >> 24); p[1] = (uint8_t)(v >> 16);
    p[2] = (uint8_t)(v >> 8);  p[3] = (uint8_t)(v & 0xFF);
}

/* Builds and sends a frame *from the board itself* on the tablet-facing
 * serial link — mirrors mesh_sim.c's send_from_node()/root_send_ack() for
 * the root's own outgoing traffic. */
static void board_send_to_tablet(board_state_t *st, uint8_t msg_type,
                                 const uint8_t dst[6], uint8_t flags,
                                 const uint8_t *payload, size_t plen)
{
    uint8_t frame[SAFR_MAX_FRAME];
    size_t len = safr_build_frame(
        frame, msg_type, ++st->msg_id, st->mac, dst,
        7, 0, flags, st->boot_ctr, ++st->msg_ctr, payload, plen);
    if (len > 0) serial_link_send(frame, len);
}

static void send_ack(board_state_t *st, uint16_t acked_msg_id, uint8_t status,
                     const uint8_t dst[6])
{
    uint8_t p[4] = {(uint8_t)(acked_msg_id >> 8), (uint8_t)(acked_msg_id & 0xFF),
                    status, 0x00};
    board_send_to_tablet(st, SAFR_MSG_ACK, dst, 0, p, sizeof(p));
}

/* ── Children tracking (drives the HEARTBEAT/TOPOLOGY shim's child list) ── */

static void track_child(board_state_t *st, const uint8_t mac[6], int64_t now_ms)
{
    int free_slot = -1;
    for (int i = 0; i < BOARD_MAX_CHILDREN; i++) {
        if (st->children[i].used && memcmp(st->children[i].mac, mac, 6) == 0) {
            st->children[i].last_seen_ms = now_ms;
            return;
        }
        if (!st->children[i].used && free_slot < 0) free_slot = i;
    }
    if (free_slot < 0) return; /* table full; drop silently, cosmetic-only shim */
    st->children[free_slot].used = true;
    memcpy(st->children[free_slot].mac, mac, 6);
    st->children[free_slot].last_seen_ms = now_ms;
}

/* ── RAM ring journal (spec §8) ────────────────────────────────────────── */

static void journal_append(board_state_t *st, const uint8_t mac[6],
                           const uint8_t payload[17])
{
    board_journal_entry_t *j = &st->journal[st->journal_top % BOARD_JOURNAL_CAP];
    j->jrn_seq = ++st->journal_top;
    memcpy(j->mac, mac, 6);
    memcpy(j->payload, payload, 17);
}

/* EVENT_LOG_REQ -> EVENT_LOG_DATA replay (spec §7.8/§7.9), ported from
 * mesh_sim.c's root_send_journal(). */
static void send_journal(board_state_t *st, uint32_t since_seq,
                         uint8_t max_count, const uint8_t dst[6])
{
    if (max_count == 0 || max_count > SAFR_LOG_BATCH_DEF) {
        max_count = SAFR_LOG_BATCH_DEF;
    }

    const uint32_t oldest =
        st->journal_top > BOARD_JOURNAL_CAP ? st->journal_top - BOARD_JOURNAL_CAP + 1 : 1;
    uint32_t seq = since_seq + 1 < oldest ? oldest : since_seq + 1;

    uint8_t p[SAFR_LOG_DATA_LEN];

    if (seq > st->journal_top) { /* nothing newer */
        memset(p, 0, sizeof(p));
        put_u32(&p[0], st->journal_top);
        p[4] = SAFR_LOG_F_LAST | SAFR_LOG_F_EMPTY;
        board_send_to_tablet(st, SAFR_MSG_EVENT_LOG_DATA, dst, 0, p, sizeof(p));
        return;
    }

    for (uint8_t sent = 0; seq <= st->journal_top && sent < max_count; seq++, sent++) {
        const board_journal_entry_t *j = &st->journal[(seq - 1) % BOARD_JOURNAL_CAP];
        put_u32(&p[0], j->jrn_seq);
        p[4] = (seq == st->journal_top || sent == max_count - 1) ? SAFR_LOG_F_LAST : 0;
        memcpy(&p[5], j->mac, 6);
        memcpy(&p[11], j->payload, 17);
        board_send_to_tablet(st, SAFR_MSG_EVENT_LOG_DATA, dst, 0, p, sizeof(p));
    }
}

/* ── GET_INSTALLATION -> INSTALLATION (v3.1, spec §7.6/§7.10) ───────────── */

static void send_installation(board_state_t *st, const uint8_t dst[6])
{
    uint8_t p[SAFR_MAX_PAYLOAD];
    size_t plen = installation_msg_encode(st, p);
    board_send_to_tablet(st, SAFR_MSG_INSTALLATION, dst, 0, p, plen);
}

/* ── Uplink (mesh -> tablet) ─────────────────────────────────────────────
 *
 * Every uplink frame is forwarded to the tablet byte-for-byte (it's already
 * authenticated end-to-end; the board must not re-encode it). Board only
 * *observes* it to track children and journal EVENTs. */
void root_duties_handle_uplink(board_state_t *st, const uint8_t *raw,
                               size_t raw_len, const safr_rx_frame_t *rx)
{
    int64_t now_ms = esp_timer_get_time() / 1000;
    track_child(st, rx->src_mac, now_ms);

    if (rx->msg_type == SAFR_MSG_EVENT && rx->payload_len == 17) {
        journal_append(st, rx->src_mac, rx->payload);
    }

    serial_link_send(raw, raw_len);
}

/* ── Downlink (tablet -> mesh / board) ────────────────────────────────────
 *
 * LINK_CHECK/TIME_SYNC/COMMAND: ACKed by the board itself (SRC_MAC = board
 * MAC, POC-BRIEF §4.2) *and* forwarded into the mesh unchanged so the actual
 * target device(s) also see it (e.g. TIME_SYNC must reach nodes so they set
 * their RTC, POC-BRIEF §4.3; SILENCE/TEST/RELAY_SET/IDENTIFY/RESET must
 * reach the addressed AC device to act on it).
 *
 * GET_INSTALLATION (v3.1) is addressed to the board itself, not the mesh:
 * answered locally with INSTALLATION, never forwarded.
 * EVENT_LOG_REQ is answered locally from the board's own RAM journal (the
 * board journals every uplink EVENT it forwards, see above) — also never
 * forwarded; the response *is* the confirmation (spec §7.8), no separate ACK.
 */
void root_duties_handle_downlink(board_state_t *st, const uint8_t *raw,
                                 size_t raw_len, const safr_rx_frame_t *rx)
{
    if (rx->msg_type == SAFR_MSG_COMMAND && rx->payload_len >= 1 &&
        rx->payload[0] == SAFR_CMD_GET_INSTALLATION) {
        send_installation(st, rx->src_mac);
        return;
    }

    if (rx->msg_type == SAFR_MSG_EVENT_LOG_REQ && rx->payload_len >= 5) {
        const uint32_t since = ((uint32_t)rx->payload[0] << 24) |
                               ((uint32_t)rx->payload[1] << 16) |
                               ((uint32_t)rx->payload[2] << 8) | rx->payload[3];
        send_journal(st, since, rx->payload[4], rx->src_mac);
        return;
    }

    if (rx->msg_type == SAFR_MSG_TIME_SYNC || rx->msg_type == SAFR_MSG_COMMAND) {
        /* Covers LINK_CHECK too (CMD 0x00 within COMMAND): harmless to
         * forward, nodes simply have no reaction to it (spec §9.3). */
        send_ack(st, rx->msg_id, SAFR_ACK_OK, rx->src_mac);
        tcp_link_send(raw, raw_len);
        return;
    }

    /* Unknown/unexpected downlink type: drop silently (console is disabled). */
}

/* ── HEARTBEAT/TOPOLOGY compatibility shim (spec §7.3/§7.4) ──────────────
 *
 * Fixed LAYER=0, NODE_ROLE=root, PARENT_MAC=central — the app's
 * meshLinkStateProvider needs a layer-0 device to show "mesh connected"
 * (POC-BRIEF §4.2). Children = whichever AC devices the board currently
 * hears via uplink forwarding. */

static void emit_heartbeat(board_state_t *st)
{
    uint8_t p[20];
    put_u32(&p[0], 0); /* TIMESTAMP: board has no wall clock until TIME_SYNC; spec sentinel not defined for this field, 0 is the safest "unknown" until wired up */
    put_u32(&p[4], (uint32_t)(esp_timer_get_time() / 1000000));
    p[8] = SAFR_PWR_AC_OK; /* board is mains-powered, no battery path (out of scope) */
    p[9] = SAFR_NA_U8;     /* BATTERY_PCT n/a */
    put_u16(&p[10], SAFR_NA_I16);
    p[12] = (uint8_t)SAFR_NA_RSSI; /* root: n/a, matches mesh_sim.c convention */
    memcpy(&p[13], SAFR_CENTRAL_MAC, 6);
    p[19] = 0; /* LAYER 0 */
    board_send_to_tablet(st, SAFR_MSG_HEARTBEAT, SAFR_BCAST_MAC, 0, p, sizeof(p));
}

static void emit_topology(board_state_t *st, int64_t now_ms)
{
    uint8_t p[SAFR_MAX_PAYLOAD];
    put_u32(&p[0], (uint32_t)(now_ms / 1000));
    p[4] = SAFR_ROLE_ROOT;
    p[5] = 0; /* LAYER */
    memcpy(&p[6], SAFR_CENTRAL_MAC, 6);
    p[12] = (uint8_t)SAFR_NA_RSSI;

    size_t off = 14;
    uint8_t count = 0;
    for (int i = 0; i < BOARD_MAX_CHILDREN; i++) {
        if (!st->children[i].used) continue;
        memcpy(&p[off], st->children[i].mac, 6);
        p[off + 6] = (uint8_t)SAFR_NA_RSSI; /* board doesn't see mesh-internal RSSI, only its own HEARTBEATs report real RSSI */
        off += 7;
        count++;
    }
    p[13] = count;
    board_send_to_tablet(st, SAFR_MSG_TOPOLOGY, SAFR_BCAST_MAC, 0, p, off);
}

void root_duties_step(board_state_t *st, int64_t now_ms)
{
    if (now_ms >= st->next_heartbeat_ms) {
        emit_heartbeat(st);
        st->next_heartbeat_ms = now_ms + HEARTBEAT_INTERVAL_MS;
    }
    if (now_ms >= st->next_topology_ms) {
        emit_topology(st, now_ms);
        st->next_topology_ms = now_ms + TOPOLOGY_INTERVAL_MS;
    }
}

void root_duties_init(board_state_t *st, const uint8_t board_mac[6],
                      const siot_installation_t *inst)
{
    memset(st, 0, sizeof(*st));
    memcpy(st->mac, board_mac, 6);
    st->inst = *inst;
    st->boot_ctr = (uint16_t)(2 + (esp_random() % 0xFFFD)); /* never 1: reserved for Appendix A vectors */
    st->next_heartbeat_ms = 0;
    st->next_topology_ms = 0;
}
