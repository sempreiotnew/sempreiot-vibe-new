/* siot_safr — device-side SAFR state: identity + counters, TX, the RX
 * pipeline of spec §10 (plaintext policy, replay §4, dedupe §9.1), the
 * MSG_TYPE dispatcher and the stats counters.
 *
 * Dedupe table: pocs/node/main/node_mesh.c dedup_check_and_insert() (16
 * entries, 30 s TTL), with "evict the oldest" instead of "evict slot 0".
 * Replay rule: the app's (safr_ingest_provider.dart) — equal-or-older
 * (BOOT_CTR, MSG_CTR) from the SAME boot is a replay; a different BOOT_CTR
 * starts a new sequence (a device that rebooted, or whose NVS was erased).
 */
#include <string.h>

#include "sdkconfig.h"

#include "safr_internal.h"
#include "safr_port.h"

typedef struct {
    bool     used;
    uint8_t  src_mac[6];
    uint16_t msg_id;
    int64_t  seen_ms;
} dedup_entry_t;

typedef struct {
    bool     used;
    uint8_t  src_mac[6];
    uint16_t boot_ctr;
    uint32_t msg_ctr;
    int64_t  seen_ms;
} peer_entry_t;

typedef struct {
    bool                used;
    uint8_t             msg_type;
    siot_safr_handler_t handler;
    void               *ctx;
} handler_entry_t;

static safr_lock_t s_lock;         /* counters, tables, handlers, stats */
static bool        s_lock_ready;
static bool        s_inited;

static siot_safr_config_t s_cfg;
static uint8_t     s_level;
static uint16_t    s_msg_id;       /* last MSG_ID handed out */
static uint32_t    s_msg_ctr;      /* last MSG_CTR used */

static siot_safr_tx_fn s_tx;
static void           *s_tx_ctx;

static dedup_entry_t   s_dedup[CONFIG_SIOT_SAFR_DEDUP_CAP];
static peer_entry_t    s_peers[CONFIG_SIOT_SAFR_PEERS_MAX];
static handler_entry_t s_handlers[CONFIG_SIOT_SAFR_HANDLERS_MAX];
static handler_entry_t s_default_handler; /* for every MSG_TYPE without an entry above */
static siot_safr_stats_t s_stats;

/* ---- init / identity ------------------------------------------------- */

esp_err_t siot_safr_init(const siot_safr_config_t *cfg)
{
    if (cfg == NULL || cfg->now_ms == NULL) return ESP_ERR_INVALID_ARG;

    if (!s_lock_ready) {
        safr_lock_init(&s_lock);
        s_lock_ready = true;
    }
    if (safr_codec_init(cfg->system_id, cfg->safr_psk) != 0) return ESP_FAIL;

    safr_lock(&s_lock);
    s_cfg = *cfg;
    s_msg_id = 0;
    s_msg_ctr = 0;
    memset(s_dedup, 0, sizeof(s_dedup));
    memset(s_peers, 0, sizeof(s_peers));
    memset(&s_stats, 0, sizeof(s_stats));
    s_inited = true;
    safr_unlock(&s_lock);
    return ESP_OK;
}

void siot_safr_set_tx(siot_safr_tx_fn fn, void *ctx)
{
    if (!s_lock_ready) {
        safr_lock_init(&s_lock);
        s_lock_ready = true;
    }
    safr_lock(&s_lock);
    s_tx = fn;
    s_tx_ctx = ctx;
    safr_unlock(&s_lock);
}

void siot_safr_set_level(uint8_t level)
{
    if (level > SAFR_TTL_MAX) level = SAFR_TTL_MAX;
    safr_lock(&s_lock);
    s_level = level;
    safr_unlock(&s_lock);
}

uint16_t siot_safr_next_msg_id(void)
{
    safr_lock(&s_lock);
    const uint16_t id = ++s_msg_id;
    safr_unlock(&s_lock);
    return id;
}

uint16_t siot_safr_last_msg_id(void)
{
    safr_lock(&s_lock);
    const uint16_t id = s_msg_id;
    safr_unlock(&s_lock);
    return id;
}

void siot_safr_set_last_msg_id(uint16_t last)
{
    safr_lock(&s_lock);
    s_msg_id = last;
    safr_unlock(&s_lock);
}

/* ---- TX -------------------------------------------------------------- */

esp_err_t siot_safr_send(const uint8_t dst_mac[6], uint8_t msg_type, uint16_t msg_id,
                         uint8_t flags, const uint8_t *payload, size_t payload_len)
{
    if (payload_len > SAFR_MAX_PAYLOAD) return ESP_ERR_INVALID_SIZE;
    if (!s_lock_ready) return ESP_ERR_INVALID_STATE;

    safr_lock(&s_lock);
    if (!s_inited || s_tx == NULL) {
        safr_unlock(&s_lock);
        return ESP_ERR_INVALID_STATE;
    }
    /* Fresh MSG_CTR on every frame, retransmissions included (spec §4). */
    const uint32_t msg_ctr = ++s_msg_ctr;
    const uint8_t  ttl     = (uint8_t)(SAFR_TTL_MAX - s_level);
    const uint8_t  hops    = s_level;
    const siot_safr_tx_fn tx = s_tx;
    void *tx_ctx = s_tx_ctx;
    uint8_t src_mac[6];
    memcpy(src_mac, s_cfg.src_mac, 6);
    const uint16_t boot_ctr = s_cfg.boot_ctr;
    safr_unlock(&s_lock);

    uint8_t frame[SAFR_MAX_FRAME];
    const size_t n = siot_safr_build_frame(frame, msg_type, msg_id, src_mac, dst_mac,
                                           ttl, hops, flags, boot_ctr, msg_ctr,
                                           payload, payload_len);
    if (n == 0) {
        safr_lock(&s_lock);
        s_stats.tx_failed++;
        safr_unlock(&s_lock);
        return ESP_FAIL;
    }

    safr_lock(&s_lock);
    s_stats.tx_frames++;
    safr_unlock(&s_lock);

    tx(frame, n, dst_mac, tx_ctx);
    return ESP_OK;
}

/* ---- dispatcher table ----------------------------------------------- */

static handler_entry_t *find_handler(uint8_t msg_type)
{
    for (int i = 0; i < CONFIG_SIOT_SAFR_HANDLERS_MAX; i++) {
        if (s_handlers[i].used && s_handlers[i].msg_type == msg_type) return &s_handlers[i];
    }
    return NULL;
}

esp_err_t siot_safr_register(uint8_t msg_type, siot_safr_handler_t handler, void *ctx)
{
    if (handler == NULL) return ESP_ERR_INVALID_ARG;
    if (!s_lock_ready) {
        safr_lock_init(&s_lock);
        s_lock_ready = true;
    }
    safr_lock(&s_lock);
    handler_entry_t *e = find_handler(msg_type);
    if (e == NULL) {
        for (int i = 0; i < CONFIG_SIOT_SAFR_HANDLERS_MAX; i++) {
            if (!s_handlers[i].used) { e = &s_handlers[i]; break; }
        }
    }
    if (e == NULL) {
        safr_unlock(&s_lock);
        return ESP_ERR_NO_MEM;
    }
    e->used = true;
    e->msg_type = msg_type;
    e->handler = handler;
    e->ctx = ctx;
    safr_unlock(&s_lock);
    return ESP_OK;
}

esp_err_t siot_safr_unregister(uint8_t msg_type)
{
    if (!s_lock_ready) return ESP_ERR_NOT_FOUND;
    safr_lock(&s_lock);
    handler_entry_t *e = find_handler(msg_type);
    if (e != NULL) memset(e, 0, sizeof(*e));
    safr_unlock(&s_lock);
    return e != NULL ? ESP_OK : ESP_ERR_NOT_FOUND;
}

esp_err_t siot_safr_register_default(siot_safr_handler_t handler, void *ctx)
{
    if (!s_lock_ready) {
        safr_lock_init(&s_lock);
        s_lock_ready = true;
    }
    safr_lock(&s_lock);
    s_default_handler.used = handler != NULL;
    s_default_handler.handler = handler;
    s_default_handler.ctx = ctx;
    safr_unlock(&s_lock);
    return ESP_OK;
}

/* ---- replay (spec §4) — lock held ------------------------------------ */

static bool replay_check_and_update(const siot_safr_frame_t *f, int64_t now_ms)
{
    peer_entry_t *hit = NULL, *free_slot = NULL, *oldest = NULL;
    for (int i = 0; i < CONFIG_SIOT_SAFR_PEERS_MAX; i++) {
        peer_entry_t *e = &s_peers[i];
        if (!e->used) {
            if (free_slot == NULL) free_slot = e;
            continue;
        }
        if (memcmp(e->src_mac, f->src_mac, 6) == 0) { hit = e; break; }
        if (oldest == NULL || e->seen_ms < oldest->seen_ms) oldest = e;
    }
    if (hit != NULL) {
        if (f->boot_ctr == hit->boot_ctr && f->msg_ctr <= hit->msg_ctr) {
            return true; /* replay: same boot, counter not strictly newer */
        }
    } else {
        hit = free_slot != NULL ? free_slot : oldest;
        hit->used = true;
        memcpy(hit->src_mac, f->src_mac, 6);
    }
    hit->boot_ctr = f->boot_ctr;
    hit->msg_ctr  = f->msg_ctr;
    hit->seen_ms  = now_ms;
    return false;
}

/* ---- dedupe (spec §9.1) — lock held; from node_mesh.c ---------------- */

static bool dedup_check_and_insert(const siot_safr_frame_t *f, int64_t now_ms)
{
    dedup_entry_t *free_slot = NULL, *oldest = NULL;
    for (int i = 0; i < CONFIG_SIOT_SAFR_DEDUP_CAP; i++) {
        dedup_entry_t *e = &s_dedup[i];
        if (!e->used || now_ms - e->seen_ms > CONFIG_SIOT_SAFR_DEDUP_TTL_MS) {
            if (free_slot == NULL) free_slot = e;
            continue;
        }
        if (e->msg_id == f->msg_id && memcmp(e->src_mac, f->src_mac, 6) == 0) {
            return true; /* already seen */
        }
        if (oldest == NULL || e->seen_ms < oldest->seen_ms) oldest = e;
    }
    dedup_entry_t *slot = free_slot != NULL ? free_slot : oldest;
    slot->used = true;
    memcpy(slot->src_mac, f->src_mac, 6);
    slot->msg_id  = f->msg_id;
    slot->seen_ms = now_ms;
    return false;
}

/* ---- RX pipeline (spec §10) ------------------------------------------ */

siot_safr_rx_result_t siot_safr_rx(const uint8_t *buf, size_t len)
{
    if (!s_lock_ready || !s_inited) return SIOT_SAFR_RX_NOT_INIT;

    safr_lock(&s_lock);
    s_stats.rx_frames++;
    const bool allow_plain = s_cfg.allow_plaintext;
    safr_unlock(&s_lock);

    /* Steps 3, 5, 7: CRC → SYSTEM_ID → CCM. Decryption needs no state lock,
     * the codec has its own CCM lock. */
    siot_safr_frame_t f;
    const siot_safr_parse_result_t pr = siot_safr_parse_frame(buf, len, &f);

    safr_lock(&s_lock);
    switch (pr) {
    case SIOT_SAFR_PARSE_BAD_FRAME:
        s_stats.bad_frame++;
        safr_unlock(&s_lock);
        return SIOT_SAFR_RX_BAD_FRAME;
    case SIOT_SAFR_PARSE_FOREIGN:
        s_stats.foreign++;
        safr_unlock(&s_lock);
        return SIOT_SAFR_RX_FOREIGN;
    case SIOT_SAFR_PARSE_AUTH_FAILED:
        s_stats.auth++;
        safr_unlock(&s_lock);
        return SIOT_SAFR_RX_AUTH_FAILED;
    case SIOT_SAFR_PARSE_OK:
        break;
    }

    /* Step 6: plaintext is a bench facility only (spec §4.1). */
    if ((f.flags & SAFR_F_ENC) == 0 && !allow_plain) {
        s_stats.plaintext_rejected++;
        safr_unlock(&s_lock);
        return SIOT_SAFR_RX_PLAINTEXT_REJECTED;
    }

    const int64_t now_ms = s_cfg.now_ms();

    /* Step 8: replay — diagnostic only, no state change, no ACK. */
    if (replay_check_and_update(&f, now_ms)) {
        s_stats.replay++;
        safr_unlock(&s_lock);
        return SIOT_SAFR_RX_REPLAY;
    }

    /* Step 9: dedupe — process once, ACK every time. */
    const bool duplicate = dedup_check_and_insert(&f, now_ms);

    const handler_entry_t *e = find_handler(f.msg_type);
    if (e == NULL && s_default_handler.used) e = &s_default_handler;
    if (e == NULL) {
        s_stats.no_handler++;
        safr_unlock(&s_lock);
        return SIOT_SAFR_RX_NO_HANDLER;
    }
    const siot_safr_handler_t handler = e->handler;
    void *ctx = e->ctx;
    if (duplicate) s_stats.dup++; else s_stats.rx_ok++;
    safr_unlock(&s_lock);

    /* Step 10 is the handler's: ACK if F_ACK_REQ, even when duplicate. */
    handler(&f, buf, len, duplicate, ctx);
    return duplicate ? SIOT_SAFR_RX_DUPLICATE : SIOT_SAFR_RX_OK;
}

/* ---- stats ----------------------------------------------------------- */

void siot_safr_get_stats(siot_safr_stats_t *out)
{
    if (out == NULL) return;
    if (!s_lock_ready) {
        memset(out, 0, sizeof(*out));
        return;
    }
    safr_lock(&s_lock);
    *out = s_stats;
    safr_unlock(&s_lock);
}

void siot_safr_reset_stats(void)
{
    if (!s_lock_ready) return;
    safr_lock(&s_lock);
    memset(&s_stats, 0, sizeof(s_stats));
    safr_unlock(&s_lock);
}
