#include "siot_leaf_proto.h"

#include <string.h>

#include "siot_safr.h"
#include "siot_util.h"

/* ---- §12.4 ---------------------------------------------------------------- */

bool siot_leaf_ack_parse(const uint8_t *p, size_t len, siot_leaf_ack_t *out)
{
    if (!p || !out) return false;
    if (len != SIOT_LEAF_ACK_LEN && len != SIOT_LEAF_ACK_EXT_LEN) return false;
    memset(out, 0, sizeof(*out));
    out->acked_msg_id = siot_get_u16(&p[0]);
    out->code    = p[2] & SAFR_ACK_CODE_MASK;
    out->pending = (p[2] & SAFR_ACK_F_PENDING) != 0;
    out->no_path = (p[2] & SAFR_ACK_F_NO_PATH) != 0;
    out->detail  = p[3];
    if (len == SIOT_LEAF_ACK_EXT_LEN) {
        out->has_ext = true;
        out->epoch   = siot_get_u32(&p[4]);
        out->channel = p[8];
    }
    return true;
}

size_t siot_leaf_ack_build(uint8_t out[SIOT_LEAF_ACK_EXT_LEN], uint16_t acked_msg_id,
                           uint8_t code, uint8_t pending_count, bool no_path,
                           uint32_t epoch, uint8_t channel)
{
    uint8_t status = code & SAFR_ACK_CODE_MASK;
    if (pending_count) status |= SAFR_ACK_F_PENDING;
    if (no_path) status |= SAFR_ACK_F_NO_PATH;
    siot_put_u16(&out[0], acked_msg_id);
    out[2] = status;
    out[3] = pending_count;
    siot_put_u32(&out[4], epoch);
    out[8] = channel;
    return SIOT_LEAF_ACK_EXT_LEN;
}

/* ---- §12.3 ---------------------------------------------------------------- */

int siot_leaf_pick_parent(const siot_leaf_candidate_t *c, size_t n)
{
    int best = -1;
    for (size_t i = 0; i < n; i++) {
        if (best < 0) { best = (int)i; continue; }
        const siot_leaf_candidate_t *b = &c[best], *x = &c[i];
        const bool b_mesh = b->layer != 0xFF, x_mesh = x->layer != 0xFF;
        if (b_mesh != x_mesh) { if (x_mesh) best = (int)i; continue; }
        if (x->link > b->link) { best = (int)i; continue; }
        if (x->link == b->link && x->layer < b->layer) best = (int)i;
    }
    return best;
}

/* ---- §12.6 outbox ---------------------------------------------------------- */

void siot_leaf_outbox_init(siot_leaf_outbox_t *o)
{
    memset(o, 0, sizeof(*o));
}

uint8_t siot_leaf_outbox_count(const siot_leaf_outbox_t *o)
{
    return o->count;
}

static void outbox_remove_at(siot_leaf_outbox_t *o, uint8_t logical)
{
    /* Shift everything after `logical` (0 = oldest) one slot towards the head. */
    for (uint8_t k = logical; k + 1 < o->count; k++) {
        const uint8_t from = (uint8_t)((o->head + k + 1) % SIOT_LEAF_OUTBOX_CAP);
        const uint8_t to   = (uint8_t)((o->head + k) % SIOT_LEAF_OUTBOX_CAP);
        memcpy(o->entry[to], o->entry[from], 17);
    }
    o->count--;
}

bool siot_leaf_outbox_push(siot_leaf_outbox_t *o, const uint8_t payload[17])
{
    bool dropped = false;
    if (o->count >= SIOT_LEAF_OUTBOX_CAP) {
        uint8_t victim = 0; /* oldest */
        for (uint8_t k = 0; k < o->count; k++) {
            const uint8_t idx = (uint8_t)((o->head + k) % SIOT_LEAF_OUTBOX_CAP);
            if (o->entry[idx][0] != SAFR_EVT_ALARM) { victim = k; break; }
        }
        outbox_remove_at(o, victim);
        dropped = true;
    }
    const uint8_t slot = (uint8_t)((o->head + o->count) % SIOT_LEAF_OUTBOX_CAP);
    memcpy(o->entry[slot], payload, 17);
    o->count++;
    return dropped;
}

bool siot_leaf_outbox_peek(const siot_leaf_outbox_t *o, uint8_t payload[17])
{
    if (o->count == 0) return false;
    memcpy(payload, o->entry[o->head], 17);
    return true;
}

void siot_leaf_outbox_pop(siot_leaf_outbox_t *o)
{
    if (o->count == 0) return;
    o->head = (uint8_t)((o->head + 1) % SIOT_LEAF_OUTBOX_CAP);
    o->count--;
}

/* ---- parent side ------------------------------------------------------------ */

siot_leaf_rx_kind_t siot_leaf_rx_check(siot_leaf_rx_state_t *st, uint16_t boot_ctr, uint32_t msg_ctr, uint16_t msg_id)
{
    if (st->seen && boot_ctr == st->boot_ctr && msg_ctr <= st->msg_ctr) return SIOT_LEAF_RX_REPLAY;
    /* A leaf's MSG_ID restarts with every wake (a wake is a boot): a repeat
     * is only a duplicate inside the same boot. */
    const bool dup = st->seen && boot_ctr == st->boot_ctr && msg_id == st->msg_id;
    st->seen = true;
    st->boot_ctr = boot_ctr;
    st->msg_ctr = msg_ctr;
    st->msg_id = msg_id;
    return dup ? SIOT_LEAF_RX_DUP : SIOT_LEAF_RX_NEW;
}

void siot_leaf_mailbox_init(siot_leaf_mailbox_t *m) { memset(m, 0, sizeof(*m)); }

uint8_t siot_leaf_mailbox_count(const siot_leaf_mailbox_t *m)
{
    uint8_t n = 0;
    for (int i = 0; i < SIOT_LEAF_MAILBOX_CAP; i++) if (m->e[i].len) n++;
    return n;
}

const siot_leaf_mail_t *siot_leaf_mailbox_oldest(const siot_leaf_mailbox_t *m)
{
    const siot_leaf_mail_t *best = NULL;
    for (int i = 0; i < SIOT_LEAF_MAILBOX_CAP; i++) {
        if (!m->e[i].len) continue;
        if (best == NULL || m->e[i].queued_ms < best->queued_ms) best = &m->e[i];
    }
    return best;
}

void siot_leaf_mailbox_remove(siot_leaf_mailbox_t *m, const siot_leaf_mail_t *e)
{
    for (int i = 0; i < SIOT_LEAF_MAILBOX_CAP; i++) if (&m->e[i] == e) m->e[i].len = 0;
}

bool siot_leaf_mailbox_push(siot_leaf_mailbox_t *m, const uint8_t *frame, size_t len, uint8_t cmd,
                            uint16_t msg_id, int64_t now_ms)
{
    if (len == 0 || len > sizeof(m->e[0].frame)) return false;
    bool displaced = false;
    siot_leaf_mail_t *slot = NULL;
    if (cmd != SIOT_LEAF_NOT_A_COMMAND) { /* newer command of the same kind replaces the older */
        for (int i = 0; i < SIOT_LEAF_MAILBOX_CAP; i++) {
            if (m->e[i].len && m->e[i].cmd == cmd) { slot = &m->e[i]; displaced = true; break; }
        }
    }
    if (slot == NULL) {
        for (int i = 0; i < SIOT_LEAF_MAILBOX_CAP; i++) if (!m->e[i].len) { slot = &m->e[i]; break; }
    }
    if (slot == NULL) { /* full: the oldest goes */
        slot = (siot_leaf_mail_t *)siot_leaf_mailbox_oldest(m);
        displaced = true;
    }
    slot->len = (uint8_t)len;
    slot->cmd = cmd;
    slot->msg_id = msg_id;
    slot->queued_ms = now_ms;
    memcpy(slot->frame, frame, len);
    return displaced;
}

bool siot_leaf_mailbox_ack(siot_leaf_mailbox_t *m, uint16_t msg_id)
{
    for (int i = 0; i < SIOT_LEAF_MAILBOX_CAP; i++) {
        if (m->e[i].len && m->e[i].msg_id == msg_id) { m->e[i].len = 0; return true; }
    }
    return false;
}

uint8_t siot_leaf_mailbox_expire(siot_leaf_mailbox_t *m, int64_t now_ms)
{
    uint8_t n = 0;
    for (int i = 0; i < SIOT_LEAF_MAILBOX_CAP; i++) {
        if (m->e[i].len && now_ms - m->e[i].queued_ms > (int64_t)SIOT_LEAF_MAILBOX_TTL_MS) { m->e[i].len = 0; n++; }
    }
    return n;
}

void siot_leaf_custody_init(siot_leaf_custody_t *c) { memset(c, 0, sizeof(*c)); }

uint8_t siot_leaf_custody_count(const siot_leaf_custody_t *c)
{
    uint8_t n = 0;
    for (int i = 0; i < SIOT_LEAF_CUSTODY_CAP; i++) if (c->e[i].len) n++;
    return n;
}

bool siot_leaf_custody_add(siot_leaf_custody_t *c, const uint8_t leaf[6], uint16_t msg_id, bool alarm,
                           const uint8_t *frame, size_t len, int64_t now_ms)
{
    if (len == 0 || len > sizeof(c->e[0].frame)) return false;
    siot_leaf_custody_entry_t *slot = NULL, *victim = NULL, *victim_alarm = NULL;
    for (int i = 0; i < SIOT_LEAF_CUSTODY_CAP; i++) {
        siot_leaf_custody_entry_t *e = &c->e[i];
        if (!e->len) { if (slot == NULL) slot = e; continue; }
        if (!e->alarm) { if (victim == NULL || e->next_ms < victim->next_ms) victim = e; }
        else if (victim_alarm == NULL || e->next_ms < victim_alarm->next_ms) victim_alarm = e;
    }
    if (slot == NULL) slot = victim != NULL ? victim : victim_alarm;
    if (slot == NULL) return false;
    slot->len = (uint8_t)len;
    memcpy(slot->leaf, leaf, 6);
    slot->msg_id = msg_id;
    slot->alarm = alarm;
    slot->attempts = 1;
    slot->next_ms = now_ms + SIOT_LEAF_CUSTODY_FAST_MS;
    memcpy(slot->frame, frame, len);
    return true;
}

bool siot_leaf_custody_ack(siot_leaf_custody_t *c, const uint8_t leaf[6], uint16_t msg_id)
{
    for (int i = 0; i < SIOT_LEAF_CUSTODY_CAP; i++) {
        siot_leaf_custody_entry_t *e = &c->e[i];
        if (e->len && e->msg_id == msg_id && memcmp(e->leaf, leaf, 6) == 0) { e->len = 0; return true; }
    }
    return false;
}

siot_leaf_custody_entry_t *siot_leaf_custody_due(siot_leaf_custody_t *c, int64_t now_ms)
{
    siot_leaf_custody_entry_t *best = NULL;
    for (int i = 0; i < SIOT_LEAF_CUSTODY_CAP; i++) {
        siot_leaf_custody_entry_t *e = &c->e[i];
        if (!e->len || e->next_ms > now_ms) continue;
        if (best == NULL || e->next_ms < best->next_ms) best = e;
    }
    return best;
}

bool siot_leaf_custody_sent(siot_leaf_custody_t *c, siot_leaf_custody_entry_t *e, int64_t now_ms)
{
    (void)c;
    if (!e->len) return false;
    if (e->attempts < 0xFF) e->attempts++;
    if (e->attempts <= SIOT_LEAF_CUSTODY_FAST_TRIES) { e->next_ms = now_ms + SIOT_LEAF_CUSTODY_FAST_MS; return false; }
    if (e->alarm) { e->next_ms = now_ms + SIOT_LEAF_CUSTODY_SLOW_MS; return false; }
    e->len = 0; /* fast phase exhausted, not an alarm: give the frame up (COMM_FAULT is the leaf's own rule) */
    return true;
}
