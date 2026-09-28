/* siot_leaf_proto — protocol §12 (v3.4) without hardware: what a leaf and a
 * parent compute, testable on the host. The runtime (siot_leafcore on the
 * leaf, the parent role on the node) calls these; it never reimplements them.
 *
 * Wire layouts: docs/safr/protocol-safr-v3.md §12 — the single source of
 * truth. Numbers here are §12.10; change the spec first.
 */
#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ---- §12.10 numbers ------------------------------------------------------ */
#define SIOT_LEAF_HB_INTERVAL_S        60   /* fixed in v3.4 (§12.12) */
#define SIOT_LEAF_WAKE_BUDGET_MS       500  /* hard cap outside alarm */
#define SIOT_LEAF_ACK_WAIT_MS          100
#define SIOT_LEAF_PROBE_LISTEN_MS      200
#define SIOT_LEAF_VERDICT_WINDOW_MS    30000
#define SIOT_LEAF_WALKTEST_ACK_MS      3000
#define SIOT_LEAF_BIND_MIN_DBM         (-85) /* prefer at or above; bind to the best anyway */
#define SIOT_LEAF_WEAK_DBM             (-75) /* reported below this */
#define SIOT_LEAF_MISSES_BEFORE_PROBE  2
#define SIOT_LEAF_REPROBE_WAKES        1440 /* once every 24 h at 60 s */
#define SIOT_LEAF_UNBOUND_PROBE_EVERY  5    /* wakes, when nobody answered at all */
#define SIOT_LEAF_MAILBOX_DRAIN_MAX    4
#define SIOT_LEAF_OUTBOX_CAP           16
#define SIOT_LEAF_SETUP_WINDOW_S       120
#define SIOT_LEAF_CANDIDATES_MAX       16   /* TOPOLOGY CHILD_COUNT cap (§7.4) */

/* ---- §12.4 leaf ACK ------------------------------------------------------ */
#define SIOT_LEAF_ACK_LEN      4  /* §7.5 form */
#define SIOT_LEAF_ACK_EXT_LEN  9  /* §12.4 form: + EPOCH u32 + CHANNEL u8 */
#define SAFR_ACK_F_PENDING     0x04
#define SAFR_ACK_F_NO_PATH     0x08
#define SAFR_ACK_CODE_MASK     0x03

typedef struct {
    uint16_t acked_msg_id;
    uint8_t  code;      /* STATUS bits 0-1: SAFR_ACK_OK / ERROR / UNKNOWN_DST */
    bool     pending;   /* STATUS bit 2 */
    bool     no_path;   /* STATUS bit 3 */
    uint8_t  detail;    /* queued-frame count when pending, else the v3.2 detail */
    bool     has_ext;   /* 9-byte form present */
    uint32_t epoch;     /* 0 = the parent has no clock */
    uint8_t  channel;   /* 0 = unknown */
} siot_leaf_ack_t;

/* Accepts the 4-byte and the 9-byte form (anything else → false). */
bool siot_leaf_ack_parse(const uint8_t *payload, size_t len, siot_leaf_ack_t *out);

/* Builds the 9-byte leaf ACK (parent → leaf). `pending_count` 0 = no PENDING
 * flag; otherwise PENDING is set and DETAIL = count. Returns 9. */
size_t siot_leaf_ack_build(uint8_t out[SIOT_LEAF_ACK_EXT_LEN], uint16_t acked_msg_id,
                           uint8_t code, uint8_t pending_count, bool no_path,
                           uint32_t epoch, uint8_t channel);

/* ---- §12.3 candidates and selection ------------------------------------- */
typedef struct {
    uint8_t mac[6];   /* SAFR SRC_MAC of the offer (the node's STA MAC: PARENT_MAC in frames) */
    uint8_t peer[6];  /* ESP-NOW source address of the offer (the interface to unicast to) */
    int8_t  link;     /* the weaker direction, dBm */
    uint8_t layer;    /* LAYER from the offer; 0xFF = not on a mesh, 0 = the board */
} siot_leaf_candidate_t;

/* The weaker of the two directions is the honest number. */
static inline int8_t siot_leaf_link(int8_t rssi_seen_by_them, int8_t rssi_we_received)
{
    return rssi_seen_by_them < rssi_we_received ? rssi_seen_by_them : rssi_we_received;
}

/* Index of the parent to bind to: best link wins, lower LAYER breaks ties;
 * a candidate that is not on a mesh (0xFF) is never chosen over one that is.
 * -1 when n == 0. */
int siot_leaf_pick_parent(const siot_leaf_candidate_t *c, size_t n);

/* ---- §12.6 outbox ring (RTC memory, NVS-mirrored by the runtime) -------- */
typedef struct {
    uint8_t count;
    uint8_t head;  /* oldest */
    uint8_t entry[SIOT_LEAF_OUTBOX_CAP][17]; /* one EVENT payload each (§7.1) */
} siot_leaf_outbox_t;

void    siot_leaf_outbox_init(siot_leaf_outbox_t *o);
uint8_t siot_leaf_outbox_count(const siot_leaf_outbox_t *o);
/* Appends an EVENT payload. When full, the oldest non-ALARM entry is dropped
 * first (the oldest ALARM only if every entry is an ALARM). Returns true when
 * something was dropped. */
bool    siot_leaf_outbox_push(siot_leaf_outbox_t *o, const uint8_t payload[17]);
/* Oldest entry (false when empty). */
bool    siot_leaf_outbox_peek(const siot_leaf_outbox_t *o, uint8_t payload[17]);
void    siot_leaf_outbox_pop(siot_leaf_outbox_t *o);

/* ---- parent side (§12.5, §12.6, §12.11) — pure, host-tested ------------------ */

/* Per-leaf receive bookkeeping: replay (same boot, counter not newer) vs
 * duplicate (same MSG_ID: a fast retry — ACK again, process once) vs new. */
typedef enum { SIOT_LEAF_RX_NEW = 0, SIOT_LEAF_RX_DUP, SIOT_LEAF_RX_REPLAY } siot_leaf_rx_kind_t;
typedef struct { bool seen; uint16_t boot_ctr; uint32_t msg_ctr; uint16_t msg_id; } siot_leaf_rx_state_t;
siot_leaf_rx_kind_t siot_leaf_rx_check(siot_leaf_rx_state_t *st, uint16_t boot_ctr, uint32_t msg_ctr, uint16_t msg_id);

/* Mailbox (§12.5): raw downlink frames kept for a sleeping leaf. */
#define SIOT_LEAF_MAILBOX_CAP   SIOT_LEAF_MAILBOX_DRAIN_MAX  /* 4 */
#define SIOT_LEAF_MAILBOX_TTL_MS (3u * SIOT_LEAF_HB_INTERVAL_S * 1000u) /* 180 s */
#define SIOT_LEAF_NOT_A_COMMAND 0xFF
typedef struct {
    uint8_t  len;              /* 0 = free */
    uint8_t  cmd;              /* COMMAND CMD byte, or SIOT_LEAF_NOT_A_COMMAND (e.g. an ACK) */
    uint16_t msg_id;           /* the frame's MSG_ID (a leaf ACK for it clears the entry) */
    int64_t  queued_ms;
    uint8_t  frame[250];       /* SAFR_MAX_FRAME */
} siot_leaf_mail_t;
typedef struct { siot_leaf_mail_t e[SIOT_LEAF_MAILBOX_CAP]; } siot_leaf_mailbox_t;

void    siot_leaf_mailbox_init(siot_leaf_mailbox_t *m);
uint8_t siot_leaf_mailbox_count(const siot_leaf_mailbox_t *m);
/* Queues a frame. A newer COMMAND with the same CMD replaces the older one;
 * when full the oldest entry is dropped. Returns true when something was replaced or dropped. */
bool    siot_leaf_mailbox_push(siot_leaf_mailbox_t *m, const uint8_t *frame, size_t len, uint8_t cmd,
                               uint16_t msg_id, int64_t now_ms);
/* Oldest entry, or NULL. */
const siot_leaf_mail_t *siot_leaf_mailbox_oldest(const siot_leaf_mailbox_t *m);
void    siot_leaf_mailbox_remove(siot_leaf_mailbox_t *m, const siot_leaf_mail_t *e);
/* Drops the entry whose MSG_ID the leaf acknowledged; true if one was. */
bool    siot_leaf_mailbox_ack(siot_leaf_mailbox_t *m, uint16_t msg_id);
/* Drops entries older than SIOT_LEAF_MAILBOX_TTL_MS; returns how many. */
uint8_t siot_leaf_mailbox_expire(siot_leaf_mailbox_t *m, int64_t now_ms);

/* Custody (§12.6): a leaf EVENT the parent acknowledged and must deliver to
 * the board. Retries are the identical bytes (§9.1 — the central ACKs every
 * time): 3 fast retries 2 s apart, then, for an ALARM only, every 60 s for ever. */
#define SIOT_LEAF_CUSTODY_CAP        32
#define SIOT_LEAF_CUSTODY_FAST_MS    2000
#define SIOT_LEAF_CUSTODY_FAST_TRIES 3
#define SIOT_LEAF_CUSTODY_SLOW_MS    60000
typedef struct {
    uint8_t  len;              /* 0 = free */
    uint8_t  leaf[6];
    uint16_t msg_id;
    bool     alarm;
    uint8_t  attempts;         /* sends so far (1 = the first forward) */
    int64_t  next_ms;
    uint8_t  frame[250];
} siot_leaf_custody_entry_t;
typedef struct { siot_leaf_custody_entry_t e[SIOT_LEAF_CUSTODY_CAP]; } siot_leaf_custody_t;

void siot_leaf_custody_init(siot_leaf_custody_t *c);
uint8_t siot_leaf_custody_count(const siot_leaf_custody_t *c);
/* Records a forwarded EVENT (attempts = 1, next retry in 2 s). Full: the
 * oldest non-ALARM entry is dropped (an ALARM only if every entry is one). */
bool siot_leaf_custody_add(siot_leaf_custody_t *c, const uint8_t leaf[6], uint16_t msg_id, bool alarm,
                           const uint8_t *frame, size_t len, int64_t now_ms);
/* The board's / central's ACK for (leaf, msg_id) arrived: entry released. */
bool siot_leaf_custody_ack(siot_leaf_custody_t *c, const uint8_t leaf[6], uint16_t msg_id);
/* Next entry due for a retry at `now_ms` (NULL = none). The caller resends
 * e->frame and then calls siot_leaf_custody_sent(). */
siot_leaf_custody_entry_t *siot_leaf_custody_due(siot_leaf_custody_t *c, int64_t now_ms);
/* Schedules the next retry, or releases a non-ALARM entry whose fast phase
 * is exhausted (returns true when released = COMM_FAULT for that event). */
bool siot_leaf_custody_sent(siot_leaf_custody_t *c, siot_leaf_custody_entry_t *e, int64_t now_ms);

/* ---- policy -------------------------------------------------------------- */
/* Bound leaf: probe again after this many consecutive misses. */
static inline bool siot_leaf_probe_after_misses(uint8_t misses)
{
    return misses >= SIOT_LEAF_MISSES_BEFORE_PROBE;
}
/* Unbound leaf: probe on this wake? `heard_any` = the last probe got offers
 * (nodes exist, none online yet) → every wake; nobody → every 5th wake. */
static inline bool siot_leaf_probe_due_unbound(uint16_t wakes_since_probe, bool heard_any)
{
    return heard_any || wakes_since_probe >= SIOT_LEAF_UNBOUND_PROBE_EVERY;
}
/* Time left in the wake budget (0 when exhausted). */
static inline uint32_t siot_leaf_budget_left_ms(int64_t awake_ms, uint32_t budget_ms)
{
    return awake_ms >= (int64_t)budget_ms ? 0u : (uint32_t)(budget_ms - awake_ms);
}

#ifdef __cplusplus
}
#endif
