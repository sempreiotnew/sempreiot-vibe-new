#include "siot_coordinator.h"

#include <string.h>

#include "esp_log.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "freertos/task.h"

#include "coord_internal.h"
#include "siot_board_def.h"
#include "siot_config.h"
#include "siot_devtab.h"
#include "siot_evbus.h"
#include "siot_identity.h"
#include "siot_link.h"
#include "siot_safr.h"
#include "siot_survey.h"
#include "siot_util.h"
#include "siot_version.h"

static const char *TAG = "siot_coord";

#define HEARTBEAT_INTERVAL_MS 15000
#define TOPOLOGY_INTERVAL_MS  60000
#define TOPOLOGY_MAX_CHILDREN    26 /* 14 + 7·26 = 196 ≤ SAFR_MAX_PAYLOAD */
#define JOURNAL_CAP              64 /* RAM ring (spec §8); flash-persisted in step 4 */
#define STEP_MS                 250

typedef struct { uint32_t jrn_seq; uint8_t mac[6]; uint8_t payload[SAFR_EVENT_LEN]; } journal_entry_t;

static SemaphoreHandle_t s_lock;
static journal_entry_t s_journal[JOURNAL_CAP];
static uint32_t        s_journal_top;             /* highest JRN_SEQ, 0 = none */
static siot_link_kind_t s_rx_kind;                /* which link the frame being dispatched came from */
static siot_devtab_entry_t s_snap[SIOT_DEVTAB_CAP]; /* snapshot buffer — lock held while used */

/* The unit currently bridging the mesh to us: SRC of the last uplink
 * HEARTBEAT with LAYER 1 / TOPOLOGY with ROLE root (lock held). When its TCP
 * session drops we know it is gone ~5 s after the fact — 45 s before the
 * silence rule would say so — and tell the tablet at once (spec §9.2). */
static uint8_t s_root_mac[6];
static bool    s_root_known;

static int64_t now_ms(void) { return esp_timer_get_time() / 1000; }
static void emit_heartbeat(void);

/* Wall clock: the board's own clock comes from TIME_SYNC (brief §8 item 12,
 * not wired yet) — first_seen stays 0 until then. */
static uint32_t epoch_now(void) { return 0; }

/* ---- TX: everything the board originates goes to the tablet ------------ */

/* The one frame that is not a COMMAND and still goes down: the ACK of a
 * unit's OTA_RESULT (§13.4). Set around that send, under s_tx_mesh_lock. */
static bool s_tx_to_mesh;
static SemaphoreHandle_t s_tx_mesh_lock;

static void tx_sink(const uint8_t *frame, size_t len, const uint8_t dst_mac[6], void *ctx)
{
    (void)ctx;
    if (siot_survey_tx(frame, len, dst_mac)) return; /* PARENT_OFFER: ESP-NOW, not a link */
    /* COMMANDs the board originates (TEST tap, pending SET_DEVICE /
     * DECOMMISSION) go downlink into the mesh. Everything else it originates
     * (HEARTBEAT, TOPOLOGY, ACK, INSTALLATION, DEVICE_TABLE, EVENT_LOG_DATA)
     * reports up to the tablet. Relayed frames do not pass through here. */
    const siot_link_kind_t kind = (frame[4] == SAFR_MSG_COMMAND || s_tx_to_mesh) ? SIOT_LINK_MESH
                                                                                   : SIOT_LINK_SERIAL;
    if (siot_link_send(kind, dst_mac, frame, len) == ESP_OK) {
        const siot_evt_frame_t ev = {.msg_type = frame[4]};
        siot_evbus_post(SIOT_EVT_SAFR_TX, &ev, sizeof(ev)); /* blue pulse on transmit */
    }
    /* The board's own HEARTBEAT is ALSO broadcast down the mesh (spec §7.3,
     * §9.3): it is the one downlink frame every node hears every 15 s with or
     * without a tablet, so a joined node learns the board is behind the mesh
     * (LED online, board-silence detection) instead of waiting for the
     * tablet's LINK_CHECK or a TEST tap. No root connected: nothing to do. */
    if (frame[4] == SAFR_MSG_HEARTBEAT) {
        const esp_err_t err = siot_link_send(SIOT_LINK_MESH, dst_mac, frame, len);
        if (err != ESP_OK && err != ESP_ERR_INVALID_STATE) {
            ESP_LOGD(TAG, "heartbeat downlink: %s", esp_err_to_name(err));
        }
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
    if (id != SIOT_EVT_BUTTON_TAP) return; /* double tap: coord_admin.c */
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

static void send_ack(uint16_t acked_msg_id, uint8_t status, uint8_t detail, const uint8_t dst[6])
{
    uint8_t p[4] = {(uint8_t)(acked_msg_id >> 8), (uint8_t)acked_msg_id, status, detail};
    send_to_tablet(SAFR_MSG_ACK, dst, 0, p, sizeof(p));
}

/* A COMMAND the board itself originates into the mesh (pending rename /
 * decommission, lifecycle §3.2). ACK_REQ so the node confirms. */
static void originate_command(const uint8_t dst[6], uint8_t cmd, const uint8_t *args, size_t alen)
{
    uint8_t p[2 + SAFR_MAX_PAYLOAD];
    if (alen > SAFR_MAX_PAYLOAD - 2) return;
    p[0] = cmd;
    p[1] = (uint8_t)alen;
    if (alen) memcpy(&p[2], args, alen);
    siot_safr_set_level(0);
    siot_safr_send(dst, SAFR_MSG_COMMAND, siot_safr_next_msg_id(), SAFR_F_ACK_REQ, p, 2 + alen);
}

static size_t build_set_device_args(const siot_devtab_entry_t *e, uint8_t *out)
{
    const size_t n_len = strnlen(e->name, SIOT_NAME_MAX_LEN);
    const size_t z_len = strnlen(e->zone, SIOT_ZONE_MAX_LEN);
    size_t off = 0;
    memcpy(&out[off], e->mac, 6);
    off += 6;
    out[off++] = (uint8_t)n_len;
    memcpy(&out[off], e->name, n_len);
    off += n_len;
    out[off++] = (uint8_t)z_len;
    memcpy(&out[off], e->zone, z_len);
    off += z_len;
    return off;
}

/* The unit just spoke: push whatever the operator queued for it while it was
 * away. One shot per sighting; the node's ACK / NAME_ANNOUNCE confirms. */
static void push_pending(const uint8_t mac[6], uint8_t flags, int64_t t)
{
    if (!(flags & (SIOT_DEV_F_PENDING_RENAME | SIOT_DEV_F_PENDING_DECOMMISSION))) return;
    siot_devtab_entry_t e;
    if (!siot_devtab_get(mac, t, &e)) return;
    char mac_s[SIOT_MAC_STR_LEN];
    if (flags & SIOT_DEV_F_PENDING_DECOMMISSION) {
        ESP_LOGW(TAG, "pending DECOMMISSION -> %s", siot_mac_to_str(mac, mac_s));
        originate_command(mac, SAFR_CMD_DECOMMISSION, mac, 6);
        siot_devtab_clear_flags(mac, SIOT_DEV_F_PENDING_DECOMMISSION);
        return; /* a unit being wiped needs no rename */
    }
    if (flags & SIOT_DEV_F_PENDING_RENAME) {
        uint8_t args[6 + 1 + SIOT_NAME_MAX_LEN + 1 + SIOT_ZONE_MAX_LEN];
        const size_t alen = build_set_device_args(&e, args);
        ESP_LOGI(TAG, "pending SET_DEVICE -> %s (%s / %s)", siot_mac_to_str(mac, mac_s), e.name, e.zone);
        originate_command(mac, SAFR_CMD_SET_DEVICE, args, alen);
        siot_devtab_clear_flags(mac, SIOT_DEV_F_PENDING_RENAME);
    }
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

/* ---- INSTALLATION / DEVICE_TABLE replies — lock held ----------------------- */

static void send_installation(const uint8_t dst[6], int64_t t)
{
    uint8_t p[SAFR_MAX_PAYLOAD];
    xSemaphoreTake(s_lock, portMAX_DELAY); /* s_snap is shared with emit_topology */
    const size_t n = siot_devtab_snapshot(s_snap, SIOT_DEVTAB_CAP, t);
    const size_t plen = coord_installation_encode(siot_config_code(), s_snap, n, p);
    xSemaphoreGive(s_lock);
    send_to_tablet(SAFR_MSG_INSTALLATION, dst, 0, p, plen);
}

/* ---- firmware update: frames for siot_ota_board (protocol §13) ------------ */

static siot_coordinator_ota_cb_t s_ota_cb;
static void *s_ota_ctx;

void siot_coordinator_set_ota_sink(siot_coordinator_ota_cb_t cb, void *ctx)
{
    s_ota_cb = cb;
    s_ota_ctx = ctx;
}

void siot_coordinator_send_to_tablet(uint8_t msg_type, uint8_t flags, const uint8_t *payload, size_t len)
{
    send_to_tablet(msg_type, SAFR_CENTRAL_MAC, flags, payload, len);
}

void siot_coordinator_ack_tablet(uint16_t acked_msg_id, uint8_t status, uint8_t detail)
{
    send_ack(acked_msg_id, status, detail, SAFR_CENTRAL_MAC);
}

bool siot_coordinator_alarm_recent(void) { return coord_admin_alarm_recent(); }

static siot_coordinator_ota_cb_t s_ota_up_cb;
static void *s_ota_up_ctx;

void siot_coordinator_set_ota_uplink_sink(siot_coordinator_ota_cb_t cb, void *ctx)
{
    s_ota_up_cb = cb;
    s_ota_up_ctx = ctx;
}

uint16_t siot_coordinator_command_unit(const uint8_t mac[6], uint8_t cmd, const uint8_t *args, size_t alen)
{
    uint8_t p[SAFR_MAX_PAYLOAD];
    if (alen > SAFR_MAX_PAYLOAD - 2) return 0;
    p[0] = cmd;
    p[1] = (uint8_t)alen;
    if (alen) memcpy(&p[2], args, alen);
    const uint16_t id = siot_safr_next_msg_id();
    siot_safr_set_level(0);
    siot_safr_send(mac, SAFR_MSG_COMMAND, id, SAFR_F_ACK_REQ, p, 2 + alen);
    return id;
}

void siot_coordinator_ack_unit(const uint8_t mac[6], uint16_t acked_msg_id, uint8_t status, uint8_t detail)
{
    const uint8_t p[4] = {(uint8_t)(acked_msg_id >> 8), (uint8_t)acked_msg_id, status, detail};
    xSemaphoreTake(s_tx_mesh_lock, portMAX_DELAY);
    s_tx_to_mesh = true;
    siot_safr_send(mac, SAFR_MSG_ACK, siot_safr_next_msg_id(), 0, p, sizeof(p));
    s_tx_to_mesh = false;
    xSemaphoreGive(s_tx_mesh_lock);
}

bool siot_coordinator_root(uint8_t mac[6])
{
    xSemaphoreTake(s_lock, portMAX_DELAY);
    const bool known = s_root_known;
    if (known) memcpy(mac, s_root_mac, 6);
    xSemaphoreGive(s_lock);
    return known;
}

static bool is_ota_command(const siot_safr_frame_t *f)
{
    return f->msg_type == SAFR_MSG_COMMAND && f->payload_len >= 1 &&
           f->payload[0] >= SAFR_CMD_OTA_BAUD && f->payload[0] <= SAFR_CMD_OTA_CONTROL;
}

static bool is_ota_push(const siot_safr_frame_t *f)
{
    return f->msg_type >= SAFR_MSG_OTA_PUSH_BEGIN && f->msg_type <= SAFR_MSG_OTA_PUSH_END;
}

/* The board's own identity (spec §7.11, v3.5): it is not an entry of its own
 * device table, so it tells the tablet what it is and what it runs with the
 * same frame every unit uses. ROLE 0xFF: the board has no mesh role. */
static void send_board_announce(const uint8_t dst[6]);
void siot_coordinator_announce_board(void) { send_board_announce(SAFR_CENTRAL_MAC); }

static void send_board_announce(const uint8_t dst[6])
{
    const siot_installation_t *code = siot_config_code();
    uint8_t p[1 + SIOT_NAME_MAX_LEN + 1 + SIOT_ZONE_MAX_LEN + 1 + SAFR_PRODUCT_MAX_LEN];
    const uint8_t name_len = (uint8_t)strnlen(code->name, SIOT_NAME_MAX_LEN);
    const uint8_t zone_len = (uint8_t)strnlen(code->zone, SIOT_ZONE_MAX_LEN);
    size_t off = 0;
    p[off++] = name_len;
    memcpy(&p[off], code->name, name_len); off += name_len;
    p[off++] = zone_len;
    memcpy(&p[off], code->zone, zone_len); off += zone_len;
    p[off++] = SIOT_DEV_ROLE_UNKNOWN;
    off += siot_safr_put_product(&p[off], siot_board_def_product(), siot_board_def()->hw_rev,
                                 siot_version_string());
    send_to_tablet(SAFR_MSG_NAME_ANNOUNCE, dst, 0, p, off);
}

/* The layout the tablet on the link understands: set by its last
 * GET_DEVICE_TABLE (format byte, v3.5) and used for the unsolicited push too.
 * A pre-v3.5 tablet never sends the byte and keeps getting the v3.2 entries. */
static bool s_dt_product;

static void send_device_table(uint8_t page, const uint8_t dst[6], int64_t t)
{
    uint8_t p[SAFR_MAX_PAYLOAD];
    xSemaphoreTake(s_lock, portMAX_DELAY);
    const bool wp = s_dt_product;
    const size_t n = siot_devtab_snapshot(s_snap, SIOT_DEVTAB_CAP, t);
    uint8_t pages = 0;
    if (page != 0) {
        const size_t plen = coord_devtable_encode_page(s_snap, n, t, page, wp, &pages, p);
        xSemaphoreGive(s_lock);
        if (plen) send_to_tablet(SAFR_MSG_DEVICE_TABLE, dst, 0, p, plen);
        return;
    }
    coord_devtable_encode_page(s_snap, n, t, 1, wp, &pages, p);
    for (uint8_t i = 1; i <= pages; i++) {
        const size_t plen = coord_devtable_encode_page(s_snap, n, t, i, wp, NULL, p);
        if (plen) send_to_tablet(SAFR_MSG_DEVICE_TABLE, dst, 0, p, plen);
    }
    xSemaphoreGive(s_lock);
}

/* ---- uplink (mesh → tablet) ------------------------------------------------ */

static uint8_t role_hint(const siot_safr_frame_t *f)
{
    if (f->msg_type == SAFR_MSG_TOPOLOGY && f->payload_len >= 5) return f->payload[4];
    if (f->msg_type == SAFR_MSG_NAME_ANNOUNCE && f->payload_len >= 2) {
        const size_t n = f->payload[0];
        if (1 + n < f->payload_len) {
            const size_t z = f->payload[1 + n];
            const size_t role_off = 2 + n + z;
            if (role_off < f->payload_len) return f->payload[role_off];
        }
    }
    return SIOT_DEV_ROLE_UNKNOWN;
}

static void adopt_name_announce(const siot_safr_frame_t *f, uint8_t role)
{
    if (f->payload_len < 2) return;
    const size_t n = f->payload[0];
    if (n > SIOT_NAME_MAX_LEN || 1 + n >= f->payload_len) return;
    const size_t z = f->payload[1 + n];
    if (z > SIOT_ZONE_MAX_LEN || 2 + n + z > f->payload_len) return;
    char name[SIOT_NAME_MAX_LEN + 1], zone[SIOT_ZONE_MAX_LEN + 1];
    memcpy(name, &f->payload[1], n);
    name[n] = '\0';
    memcpy(zone, &f->payload[2 + n], z);
    zone[z] = '\0';
    siot_devtab_announce(f->src_mac, name, zone, role);

    /* v3.5: PRODUCT ‖ HW_REV ‖ FW after the ROLE byte. Absent on older units. */
    const size_t ext = 2 + n + z + 1;
    if (ext < f->payload_len) {
        uint16_t product;
        uint8_t hw_rev;
        char fw[SAFR_FW_MAX_LEN + 1];
        if (siot_safr_get_product(&f->payload[ext], f->payload_len - ext, &product, &hw_rev, fw)) {
            siot_devtab_set_product(f->src_mac, product, hw_rev, fw);
        }
    }
}

static void handle_uplink(const siot_safr_frame_t *f, const uint8_t *raw, size_t raw_len, bool dup)
{
    const int64_t t = now_ms();
    uint8_t flags = 0;
    const uint8_t role = role_hint(f);
    /* Discovery (lifecycle §3.2): runs after CCM, so a spoofed header cannot
     * touch the table. A retired MAC is dropped here: not journaled, not
     * relayed, not counted. */
    if (siot_devtab_touch(f->src_mac, t, epoch_now(), role, &flags)) {
        char mac_s[SIOT_MAC_STR_LEN];
        ESP_LOGD(TAG, "retired unit %s still transmitting: dropped", siot_mac_to_str(f->src_mac, mac_s));
        return;
    }
    if (!dup && f->msg_type == SAFR_MSG_NAME_ANNOUNCE) adopt_name_announce(f, role);

    xSemaphoreTake(s_lock, portMAX_DELAY);
    if ((f->msg_type == SAFR_MSG_HEARTBEAT && f->payload_len >= 20 && f->payload[19] == 1) ||
        (f->msg_type == SAFR_MSG_TOPOLOGY && f->payload_len >= 6 && f->payload[4] == SAFR_ROLE_ROOT &&
         f->payload[5] == 1)) {
        memcpy(s_root_mac, f->src_mac, 6);
        s_root_known = true;
    }
    if (!dup && f->msg_type == SAFR_MSG_EVENT && f->payload_len == SAFR_EVENT_LEN) {
        journal_append(f->src_mac, f->payload);
        if (f->payload[0] == SAFR_EVT_ALARM) coord_admin_note_alarm(); /* no admin window mid-alarm */
    }
    xSemaphoreGive(s_lock);
    /* Forwarded unchanged, fast retries included: the tablet ACKs every time. */
    relay(SIOT_LINK_SERIAL, raw, raw_len);
    if (s_ota_up_cb && (f->msg_type == SAFR_MSG_OTA_STATUS || f->msg_type == SAFR_MSG_OTA_RESULT ||
                        f->msg_type == SAFR_MSG_ACK)) {
        s_ota_up_cb(f, dup, s_ota_up_ctx); /* the rollout (§13.4) */
    }
    if (!dup) push_pending(f->src_mac, flags, t);
}

/* ---- downlink (tablet → board / mesh) -------------------------------------- */

static bool parse_set_device(const uint8_t *a, size_t alen, uint8_t mac[6],
                             char name[SIOT_NAME_MAX_LEN + 1], char zone[SIOT_ZONE_MAX_LEN + 1])
{
    if (alen < 8) return false;
    memcpy(mac, a, 6);
    const size_t n = a[6];
    if (n > SIOT_NAME_MAX_LEN || 7 + n >= alen) return false;
    const size_t z = a[7 + n];
    if (z > SIOT_ZONE_MAX_LEN || 8 + n + z != alen) return false;
    memcpy(name, &a[7], n);
    name[n] = '\0';
    memcpy(zone, &a[8 + n], z);
    zone[z] = '\0';
    return true;
}

static bool is_online(const uint8_t mac[6], int64_t t)
{
    siot_devtab_entry_t e;
    return siot_devtab_get(mac, t, &e) && e.state == SIOT_DEV_ONLINE;
}

static uint8_t detail_for(esp_err_t err)
{
    switch (err) {
    case ESP_OK:                return SAFR_ACK_D_NONE;
    case ESP_ERR_NOT_FOUND:     return SAFR_ACK_D_UNKNOWN_MAC;
    case ESP_ERR_NO_MEM:        return SAFR_ACK_D_TABLE_FULL;
    case ESP_ERR_INVALID_STATE: return SAFR_ACK_D_NOT_RETIRED;
    default:                    return SAFR_ACK_D_REFUSED;
    }
}

/* v3.2 lifecycle commands (spec §7.6, lifecycle §3.2). Returns true when the
 * command was consumed here (board-only, or refused); false = legacy path. */
static bool handle_lifecycle_command(const siot_safr_frame_t *f, const uint8_t *raw, size_t raw_len, bool dup)
{
    const uint8_t cmd = f->payload[0];
    const size_t alen = f->payload_len >= 2 ? f->payload[1] : 0;
    const uint8_t *a = &f->payload[2];
    if (f->payload_len < 2 + alen) {
        send_ack(f->msg_id, SAFR_ACK_ERROR, SAFR_ACK_D_BAD_ARGS, f->src_mac);
        return true;
    }
    const int64_t t = now_ms();
    const uint8_t *board_mac = siot_identity_get()->mac;
    char mac_s[SIOT_MAC_STR_LEN];

    switch (cmd) {
    case SAFR_CMD_GET_INSTALLATION:
        send_installation(f->src_mac, t); /* the reply is the confirmation */
        return true;

    case SAFR_CMD_GET_DEVICE_TABLE:
        s_dt_product = alen >= 2 && a[1] == 1; /* v3.5 format byte; absent = v3.2 entries */
        send_device_table(alen >= 1 ? a[0] : 0, f->src_mac, t);
        if (s_dt_product) send_board_announce(f->src_mac); /* a v3.5 tablet: and this is me */
        return true;

    case SAFR_CMD_SET_DEVICE: {
        uint8_t mac[6];
        char name[SIOT_NAME_MAX_LEN + 1], zone[SIOT_ZONE_MAX_LEN + 1];
        if (!parse_set_device(a, alen, mac, name, zone) || !siot_mac_eq(mac, f->dst_mac)) {
            send_ack(f->msg_id, SAFR_ACK_ERROR, SAFR_ACK_D_BAD_ARGS, f->src_mac);
            return true;
        }
        const bool online = is_online(mac, t);
        const esp_err_t err = dup ? ESP_OK : siot_devtab_set_name_zone(mac, name, zone, online);
        ESP_LOGI(TAG, "SET_DEVICE %s -> %s / %s (%s)", siot_mac_to_str(mac, mac_s), name, zone,
                 online ? "online, relayed" : "offline, pending");
        send_ack(f->msg_id, err == ESP_OK ? SAFR_ACK_OK : SAFR_ACK_ERROR, detail_for(err), f->src_mac);
        if (err == ESP_OK && !dup) {
            relay(SIOT_LINK_MESH, raw, raw_len); /* the node ACKs + re-announces */
            if (online) siot_devtab_clear_flags(mac, SIOT_DEV_F_PENDING_RENAME);
        }
        return true;
    }

    case SAFR_CMD_RETIRE_DEVICE:
    case SAFR_CMD_UNRETIRE_DEVICE:
    case SAFR_CMD_FORGET_DEVICE: {
        if (alen != 6 || siot_mac_eq(a, board_mac) || siot_mac_is_bcast(a)) {
            send_ack(f->msg_id, SAFR_ACK_ERROR, alen != 6 ? SAFR_ACK_D_BAD_ARGS : SAFR_ACK_D_REFUSED, f->src_mac);
            return true;
        }
        esp_err_t err = ESP_OK;
        if (!dup) {
            err = cmd == SAFR_CMD_RETIRE_DEVICE   ? siot_devtab_retire(a, false)
                : cmd == SAFR_CMD_UNRETIRE_DEVICE ? siot_devtab_unretire(a)
                                                  : siot_devtab_forget(a);
        }
        ESP_LOGI(TAG, "cmd 0x%02X %s: %s", cmd, siot_mac_to_str(a, mac_s), esp_err_to_name(err));
        send_ack(f->msg_id, err == ESP_OK ? SAFR_ACK_OK : SAFR_ACK_ERROR, detail_for(err), f->src_mac);
        return true;
    }

    case SAFR_CMD_REPLACE_DEVICE: {
        if (alen != 12 || siot_mac_eq(a, board_mac) || siot_mac_eq(&a[6], board_mac) ||
            siot_mac_is_bcast(a) || siot_mac_is_bcast(&a[6]) || siot_mac_eq(a, &a[6])) {
            send_ack(f->msg_id, SAFR_ACK_ERROR, alen != 12 ? SAFR_ACK_D_BAD_ARGS : SAFR_ACK_D_REFUSED, f->src_mac);
            return true;
        }
        bool old_online = false;
        const esp_err_t err = dup ? ESP_OK : siot_devtab_replace(a, &a[6], t, &old_online);
        send_ack(f->msg_id, err == ESP_OK ? SAFR_ACK_OK : SAFR_ACK_ERROR, detail_for(err), f->src_mac);
        if (err == ESP_OK && !dup) {
            char new_s[SIOT_MAC_STR_LEN];
            ESP_LOGW(TAG, "REPLACE %s -> %s (old %s)", siot_mac_to_str(a, mac_s), siot_mac_to_str(&a[6], new_s),
                     old_online ? "online: decommissioning" : "offline: retired");
            if (old_online) {
                originate_command(a, SAFR_CMD_DECOMMISSION, a, 6);
                siot_devtab_clear_flags(a, SIOT_DEV_F_PENDING_DECOMMISSION);
            }
            if (is_online(&a[6], t)) {
                siot_devtab_entry_t e;
                if (siot_devtab_get(&a[6], t, &e)) {
                    uint8_t args[6 + 1 + SIOT_NAME_MAX_LEN + 1 + SIOT_ZONE_MAX_LEN];
                    originate_command(&a[6], SAFR_CMD_SET_DEVICE, args, build_set_device_args(&e, args));
                    siot_devtab_clear_flags(&a[6], SIOT_DEV_F_PENDING_RENAME);
                }
            }
        }
        return true;
    }

    case SAFR_CMD_DECOMMISSION: {
        /* Never broadcast, ARGS must equal DST, never the board itself. */
        if (alen != 6 || !siot_mac_eq(a, f->dst_mac) || siot_mac_is_bcast(a) || siot_mac_eq(a, board_mac)) {
            send_ack(f->msg_id, SAFR_ACK_ERROR, alen != 6 ? SAFR_ACK_D_BAD_ARGS : SAFR_ACK_D_REFUSED, f->src_mac);
            return true;
        }
        const bool online = is_online(a, t);
        const esp_err_t err = dup ? ESP_OK : siot_devtab_retire(a, !online);
        ESP_LOGW(TAG, "DECOMMISSION %s (%s)", siot_mac_to_str(a, mac_s), online ? "relayed" : "pending");
        send_ack(f->msg_id, err == ESP_OK ? SAFR_ACK_OK : SAFR_ACK_ERROR, detail_for(err), f->src_mac);
        if (err == ESP_OK && !dup) relay(SIOT_LINK_MESH, raw, raw_len);
        return true;
    }

    case SAFR_CMD_SET_INSTALLATION:
    case SAFR_CMD_GET_CODE:
        /* Setup channel only (spec §3.1): on the installation key they are refused. */
        send_ack(f->msg_id, SAFR_ACK_ERROR, SAFR_ACK_D_REFUSED, f->src_mac);
        return true;

    default:
        return false;
    }
}

static void handle_downlink(const siot_safr_frame_t *f, const uint8_t *raw, size_t raw_len, bool dup)
{
    if (is_ota_push(f) || is_ota_command(f)) { /* board only, never relayed (§13.3, §13.6) */
        if (s_ota_cb) s_ota_cb(f, dup, s_ota_ctx);
        /* DETAIL of an OTA message is a §13.7 REASON: 13 BUSY = "not now, not here" (the
         * general REFUSED is 0x05, which reads SHA_FAIL in that list). */
        else if (f->flags & SAFR_F_ACK_REQ) send_ack(f->msg_id, SAFR_ACK_ERROR, 13, f->src_mac);
        return;
    }
    if (f->msg_type == SAFR_MSG_COMMAND && f->payload_len >= 1 &&
        handle_lifecycle_command(f, raw, raw_len, dup)) {
        return;
    }
    switch (f->msg_type) {
    case SAFR_MSG_COMMAND:   /* LINK_CHECK and every legacy device command */
    case SAFR_MSG_TIME_SYNC:
        send_ack(f->msg_id, SAFR_ACK_OK, SAFR_ACK_D_NONE, f->src_mac); /* board ACKs every time */
        if (!dup) relay(SIOT_LINK_MESH, raw, raw_len);                 /* nodes ACK on their own */
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
    if (s_rx_kind == SIOT_LINK_MESH) {
        if (is_ota_push(f)) return; /* §13.3: a push comes from the tablet, never from the mesh */
        handle_uplink(f, raw, raw_len, dup);
    } else {
        handle_downlink(f, raw, raw_len, dup);
    }
}

/* Root TCP session (link_mesh_board.c). UP: a root just connected — send our
 * HEARTBEAT now, up and down, so the whole re-formed tree has its proof of
 * the board within a second and announces itself (netcore's pending
 * announce) instead of at the next 15 s tick. DOWN: the root we knew is
 * gone — mark it missing and push the device table to the tablet unasked. */
static void on_link(siot_evt_id_t id, const void *data, void *ctx)
{
    (void)ctx;
    if (((const siot_evt_link_t *)data)->link_kind != SIOT_LINK_MESH) return;
    if (id == SIOT_EVT_LINK_UP) {
        emit_heartbeat();
        return;
    }
    uint8_t mac[6];
    xSemaphoreTake(s_lock, portMAX_DELAY);
    const bool known = s_root_known;
    memcpy(mac, s_root_mac, 6);
    xSemaphoreGive(s_lock);
    if (!known) return;
    const int64_t t = now_ms();
    char mac_s[SIOT_MAC_STR_LEN];
    if (siot_devtab_mark_missing(mac, t) == ESP_OK) {
        ESP_LOGW(TAG, "root %s session dropped -> MISSING, pushing DEVICE_TABLE", siot_mac_to_str(mac, mac_s));
        send_device_table(0, SAFR_BCAST_MAC, t);
    }
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
    /* A byte-identical retransmission from the mesh (a node's custody retry
     * for a leaf EVENT whose ACK was lost, protocol §12.6) is a "replay" to
     * this board's RAM table but must still reach the tablet, which ACKs
     * every ack-required frame (spec §9.1); nothing here processes it twice. */
    if (r == SIOT_SAFR_RX_REPLAY && kind == SIOT_LINK_MESH) relay(SIOT_LINK_SERIAL, frame, len);
    /* Setup channel on USB (spec §3.1): SYSTEM_ID 0x0000 frames are foreign
     * to the installation key but may carry GET_CODE under the sticker key. */
    if (r == SIOT_SAFR_RX_FOREIGN && kind == SIOT_LINK_SERIAL && coord_setup_handle(frame, len, true)) return;
    char src[SIOT_MAC_STR_LEN];
    ESP_LOGI(TAG, "rx %s type 0x%02X id %u from %s: %d", kind == SIOT_LINK_MESH ? "mesh" : "tablet",
             frame[4], siot_get_u16(&frame[5]), siot_mac_to_str(&frame[9], src), (int)r);
    if (r == SIOT_SAFR_RX_OK || r == SIOT_SAFR_RX_DUPLICATE) {
        siot_evt_frame_t ev = {.msg_type = frame[4]};
        memcpy(ev.src_mac, &frame[9], 6);
        siot_evbus_post(SIOT_EVT_SAFR_RX, &ev, sizeof(ev));
        /* The first frame of the tablet after a boot: tell it what this board
         * is and runs (§7.11). After the board updated itself the tablet's
         * serial port never closed, so it will not ask — and this is how it
         * learns the new version (§13.3). */
        static bool s_announced_to_tablet;
        if (kind == SIOT_LINK_SERIAL && !s_announced_to_tablet && siot_mac_eq(&frame[9], SAFR_CENTRAL_MAC)) {
            s_announced_to_tablet = true;
            send_board_announce(SAFR_CENTRAL_MAC);
        }
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
    const size_t n = siot_devtab_snapshot(s_snap, SIOT_DEVTAB_CAP, t);
    for (size_t i = 0; i < n && count < TOPOLOGY_MAX_CHILDREN; i++) {
        if (s_snap[i].state != SIOT_DEV_ONLINE) continue;
        memcpy(&p[off], s_snap[i].mac, 6);
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
    if (s_tx_mesh_lock == NULL) s_tx_mesh_lock = xSemaphoreCreateMutex();
    ESP_LOGI(TAG, "device table: %u entr%s (cap %d)", (unsigned)siot_devtab_count(),
             siot_devtab_count() == 1 ? "y" : "ies", SIOT_DEVTAB_CAP);

    /* One handler for every type the links can carry; the link kind tells up from down. */
    for (uint8_t t = SAFR_MSG_EVENT; t <= SAFR_MSG_NAME_ANNOUNCE; t++) {
        const esp_err_t err = siot_safr_register(t, on_frame, NULL);
        if (err != ESP_OK) return err;
    }
    /* Everything else — the firmware update messages (§13) and whatever a
     * later revision adds: up from the mesh it is relayed to the tablet, down
     * from the tablet it is the board's or it is dropped. */
    siot_safr_register_default(on_frame, NULL);
    siot_safr_set_level(0);
    siot_safr_set_tx(tx_sink, NULL);
    siot_link_set_rx(on_link_rx, NULL);
    esp_err_t err = siot_evbus_subscribe(SIOT_EVT_BUTTON_TAP, on_button, NULL, NULL);
    if (err != ESP_OK) return err;
    if ((err = siot_evbus_subscribe(SIOT_EVT_LINK_UP, on_link, NULL, NULL)) != ESP_OK) return err;
    if ((err = siot_evbus_subscribe(SIOT_EVT_LINK_DOWN, on_link, NULL, NULL)) != ESP_OK) return err;
    err = coord_admin_init(); /* double tap: admin window (lifecycle §11) */
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
