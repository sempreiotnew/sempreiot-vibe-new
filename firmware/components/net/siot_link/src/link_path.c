/* link_path — see siot_link_path.h. Pure: no radio, no clock, no lock (the
 * caller serialises; link_mesh_node.c holds a mutex around every call). */
#include "siot_link_path.h"

#include <string.h>

static int8_t q4_to_dbm(int16_t q4)
{
    /* Rounded to the nearest dBm; q4 is negative for every real signal. */
    const int v = q4 >= 0 ? (q4 + 8) / 16 : -((-q4 + 8) / 16);
    return (int8_t)(v < -127 ? -127 : v > 0 ? 0 : v);
}

static int8_t weaker(int8_t a, int8_t b) { return a < b ? a : b; }

/* ---- payload -------------------------------------------------------------- */

size_t siot_path_advert_encode(const siot_path_advert_t *a, uint8_t *out, size_t cap)
{
    if (a == NULL || out == NULL || a->chain_n > SIOT_PATH_MAX_CHAIN) return 0;
    const size_t len = SIOT_PATH_ADVERT_MIN_LEN + 6u * a->chain_n;
    if (cap < len) return 0;
    out[0] = SIOT_PATH_ADVERT_VER;
    const uint8_t alarm = a->alarm > SIOT_PATH_ALARM_MAX ? SIOT_PATH_ALARM_MAX : a->alarm;
    out[1] = (uint8_t)((a->complete ? SIOT_PATH_F_COMPLETE : 0) | (a->full ? SIOT_PATH_F_FULL : 0) |
                       (alarm << SIOT_PATH_F_ALARM_SHIFT) | (a->held && !a->complete ? SIOT_PATH_F_HELD : 0));
    out[2] = a->level;
    out[3] = (uint8_t)a->path;
    memcpy(&out[4], a->ap, 6);
    out[10] = a->chain_n;
    for (uint8_t i = 0; i < a->chain_n; i++) memcpy(&out[11 + 6u * i], a->chain[i], 6);
    return len;
}

bool siot_path_advert_decode(const uint8_t *p, size_t len, siot_path_advert_t *out)
{
    if (p == NULL || out == NULL || len < SIOT_PATH_ADVERT_MIN_LEN) return false;
    if (p[0] != SIOT_PATH_ADVERT_VER) return false;
    const uint8_t n = p[10];
    if (n > SIOT_PATH_MAX_CHAIN || len < SIOT_PATH_ADVERT_MIN_LEN + 6u * n) return false;
    memset(out, 0, sizeof(*out));
    out->complete = (p[1] & SIOT_PATH_F_COMPLETE) != 0;
    out->full = (p[1] & SIOT_PATH_F_FULL) != 0;
    out->alarm = (uint8_t)((p[1] & SIOT_PATH_F_ALARM_MASK) >> SIOT_PATH_F_ALARM_SHIFT);
    out->held = (p[1] & SIOT_PATH_F_HELD) != 0 && !out->complete;
    out->level = p[2];
    out->path = (int8_t)p[3];
    memcpy(out->ap, &p[4], 6);
    out->chain_n = n;
    for (uint8_t i = 0; i < n; i++) memcpy(out->chain[i], &p[11 + 6u * i], 6);
    return out->level >= 1;
}

/* ---- table ---------------------------------------------------------------- */

void siot_path_init(siot_path_table_t *t, const uint8_t self_ap[6])
{
    memset(t, 0, sizeof(*t));
    memcpy(t->self_ap, self_ap, 6);
}

bool siot_path_fresh(const siot_path_neighbour_t *n, int64_t now_ms)
{
    return n != NULL && n->used && n->heard >= SIOT_PATH_MIN_HEARD && now_ms - n->last_ms <= SIOT_PATH_FRESH_MS;
}

int8_t siot_path_rssi(const siot_path_neighbour_t *n) { return q4_to_dbm(n->rssi_q4); }

const siot_path_neighbour_t *siot_path_find_ap(const siot_path_table_t *t, const uint8_t ap[6])
{
    for (int i = 0; i < SIOT_PATH_NEIGHBOURS; i++) {
        if (t->n[i].used && memcmp(t->n[i].ap, ap, 6) == 0) return &t->n[i];
    }
    return NULL;
}

bool siot_path_heard(siot_path_table_t *t, int64_t now_ms, const uint8_t id[6], uint16_t boot_ctr,
                     uint32_t msg_ctr, int8_t rssi, const siot_path_advert_t *a)
{
    if (memcmp(a->ap, t->self_ap, 6) == 0) return false; /* our own, come back */

    /* A place for a new one: an empty entry, else the one silent the longest
     * — but only one that is no longer fresh. */
    siot_path_neighbour_t *e = NULL, *empty = NULL, *stale = NULL;
    for (int i = 0; i < SIOT_PATH_NEIGHBOURS; i++) {
        siot_path_neighbour_t *n = &t->n[i];
        if (n->used && memcmp(n->id, id, 6) == 0) { e = n; break; }
        if (!n->used) {
            if (empty == NULL) empty = n;
        } else if (now_ms - n->last_ms > SIOT_PATH_FRESH_MS && (stale == NULL || n->last_ms < stale->last_ms)) {
            stale = n;
        }
    }
    if (e != NULL) {
        if (boot_ctr == e->boot_ctr && msg_ctr <= e->msg_ctr) return false; /* replay */
    } else {
        e = empty != NULL ? empty : stale;
        if (e == NULL) return false;
        memset(e, 0, sizeof(*e));
        e->used = true;
        memcpy(e->id, id, 6);
    }

    const bool gap = e->heard == 0 || now_ms - e->last_ms > SIOT_PATH_FRESH_MS;
    if (gap) {
        e->heard = 1;
        e->rssi_q4 = (int16_t)(rssi * 16);
    } else {
        if (e->heard < 0xFF) e->heard++;
        e->rssi_q4 = (int16_t)(e->rssi_q4 + (rssi * 16 - e->rssi_q4) / 4);
    }
    e->last_ms = now_ms;
    e->boot_ctr = boot_ctr;
    e->msg_ctr = msg_ctr;
    memcpy(e->ap, a->ap, 6);
    e->level = a->level;
    e->path = a->path;
    e->complete = a->complete;
    e->full = a->full;
    e->alarm = a->alarm;
    e->held = a->held;
    e->under_me = false;
    for (uint8_t i = 0; i < a->chain_n; i++) {
        if (memcmp(a->chain[i], t->self_ap, 6) == 0) { e->under_me = true; break; }
    }
    e->chain_n = a->chain_n;
    memcpy(e->chain, a->chain, sizeof(e->chain));
    /* The parent this unit lost is back, with a path: nothing to pass over. */
    if (t->lost_until_ms != 0 && a->complete && memcmp(a->ap, t->lost_ap, 6) == 0) t->lost_until_ms = 0;

    if (t->has_parent && memcmp(a->ap, t->parent_ap, 6) == 0) {
        t->parent_chain_n = a->chain_n;
        memcpy(t->parent_chain, a->chain, sizeof(t->parent_chain));
    }
    return true;
}

void siot_path_set_parent(siot_path_table_t *t, const uint8_t parent_ap[6])
{
    if (parent_ap == NULL) {
        if (!t->has_parent) return;
        t->has_parent = false;
    } else {
        if (t->has_parent && memcmp(t->parent_ap, parent_ap, 6) == 0) return;
        t->has_parent = true;
        memcpy(t->parent_ap, parent_ap, 6);
    }
    t->parent_chain_n = 0;
    t->link_known = false;
    t->better_since_ms = 0;
}

void siot_path_link_sample(siot_path_table_t *t, int8_t rssi)
{
    if (!t->link_known) {
        t->link_known = true;
        t->link_q4 = (int16_t)(rssi * 16);
    } else {
        t->link_q4 = (int16_t)(t->link_q4 + (rssi * 16 - t->link_q4) / 4);
    }
}

void siot_path_own(const siot_path_table_t *t, int64_t now_ms, uint8_t level, bool root, bool root_proven,
                   bool full, siot_path_advert_t *out)
{
    memset(out, 0, sizeof(*out));
    memcpy(out->ap, t->self_ap, 6);
    out->level = level;
    out->full = full;
    if (root) {
        out->path = SIOT_PATH_ROOT_DBM;
        out->complete = root_proven;
        return;
    }
    const int8_t link = t->link_known ? q4_to_dbm(t->link_q4) : SIOT_PATH_ROOT_DBM;
    out->path = link;
    if (!t->has_parent) return;
    memcpy(out->chain[0], t->parent_ap, 6);
    out->chain_n = 1;
    const siot_path_neighbour_t *p = siot_path_find_ap(t, t->parent_ap);
    if (!t->link_known || !siot_path_fresh(p, now_ms) || !p->complete) return;
    if (t->parent_chain_n + 1u > SIOT_PATH_MAX_CHAIN) return; /* deeper than the mesh goes: not believed */
    for (uint8_t i = 0; i < t->parent_chain_n; i++) memcpy(out->chain[1 + i], t->parent_chain[i], 6);
    out->chain_n = (uint8_t)(1 + t->parent_chain_n);
    out->path = weaker(link, p->path);
    out->complete = true;
}

/* The path this unit has: its link, and what its parent says is above — when
 * the parent says nothing we believe, the link alone (the unit then moves
 * less, never more). */
static int8_t path_now(const siot_path_table_t *t, int64_t now_ms)
{
    const int8_t link = q4_to_dbm(t->link_q4);
    const siot_path_neighbour_t *p = siot_path_find_ap(t, t->parent_ap);
    return siot_path_fresh(p, now_ms) && p->complete ? weaker(link, p->path) : link;
}

/* It is the parent this unit lost (as it was heard before the loss), or it
 * hangs from it: what it says of its path is older than the news. */
static bool through_lost(const siot_path_table_t *t, int64_t now_ms, const siot_path_neighbour_t *n)
{
    if (t->lost_until_ms == 0 || now_ms >= t->lost_until_ms) return false;
    if (memcmp(n->ap, t->lost_ap, 6) == 0) return n->last_ms <= t->lost_at_ms || !n->complete;
    for (uint8_t i = 0; i < n->chain_n && i < SIOT_PATH_MAX_CHAIN; i++) {
        if (memcmp(n->chain[i], t->lost_ap, 6) == 0) return true;
    }
    return false;
}

/* The neighbour with the best path among those that can be a parent at all.
 * `rescue`: for a unit with no path (see through_lost). */
static bool best_parent(const siot_path_table_t *t, int64_t now_ms, bool rescue, siot_path_choice_t *out)
{
    const siot_path_neighbour_t *best = NULL;
    int8_t best_path = -128;
    for (int i = 0; i < SIOT_PATH_NEIGHBOURS; i++) {
        const siot_path_neighbour_t *n = &t->n[i];
        if (!siot_path_fresh(n, now_ms) || !n->complete || n->full || n->under_me) continue;
        if (n->level > SIOT_PATH_MAX_PARENT_LEVEL) continue;
        if (n->bad_until_ms != 0 && now_ms < n->bad_until_ms) continue;
        if (t->has_parent && memcmp(n->ap, t->parent_ap, 6) == 0) continue;
        if (rescue && through_lost(t, now_ms, n)) continue;
        const int8_t path = weaker(siot_path_rssi(n), n->path);
        /* The better path; then the shallower unit; then the one heard better. */
        if (best == NULL || path > best_path ||
            (path == best_path && (n->level < best->level ||
                                   (n->level == best->level && n->rssi_q4 > best->rssi_q4)))) {
            best = n;
            best_path = path;
        }
    }
    if (best == NULL) return false;
    memcpy(out->id, best->id, 6);
    memcpy(out->ap, best->ap, 6);
    out->level = best->level;
    out->rssi = siot_path_rssi(best);
    out->path_new = best_path;
    out->path_now = -128;
    return true;
}

bool siot_path_best(const siot_path_table_t *t, int64_t now_ms, siot_path_choice_t *out)
{
    if (!t->has_parent || !t->link_known) return false;
    if (!best_parent(t, now_ms, false, out)) return false;
    out->path_now = path_now(t, now_ms);
    return true;
}

bool siot_path_rescue(const siot_path_table_t *t, int64_t now_ms, siot_path_choice_t *out)
{
    return best_parent(t, now_ms, true, out);
}

uint8_t siot_path_alarm(const siot_path_table_t *t, int64_t now_ms, bool own)
{
    if (own) return 1;
    /* One advert is enough here (no SIOT_PATH_MIN_HEARD): the cost of
     * believing it is a move that waits. */
    uint8_t nearest = 0;
    for (int i = 0; i < SIOT_PATH_NEIGHBOURS; i++) {
        const siot_path_neighbour_t *n = &t->n[i];
        if (!n->used || n->alarm == 0 || now_ms - n->last_ms > SIOT_PATH_FRESH_MS) continue;
        if (nearest == 0 || n->alarm < nearest) nearest = n->alarm;
    }
    return nearest != 0 && nearest < SIOT_PATH_ALARM_MAX ? (uint8_t)(nearest + 1) : 0;
}

bool siot_path_evaluate(siot_path_table_t *t, int64_t now_ms, uint32_t sustain_ms, int8_t gain_db,
                        siot_path_choice_t *out)
{
    siot_path_choice_t c;
    if (!siot_path_best(t, now_ms, &c) || c.path_now >= SIOT_PATH_GOOD_DBM ||
        c.path_new < c.path_now + gain_db) {
        t->better_since_ms = 0;
        return false;
    }
    if (t->better_since_ms == 0) t->better_since_ms = now_ms;
    if (now_ms - t->better_since_ms < (int64_t)sustain_ms) return false;
    t->better_since_ms = 0;
    *out = c;
    return true;
}

void siot_path_evaluate_reset(siot_path_table_t *t) { t->better_since_ms = 0; }

void siot_path_mark_bad_for(siot_path_table_t *t, int64_t now_ms, const uint8_t ap[6], uint32_t ms)
{
    for (int i = 0; i < SIOT_PATH_NEIGHBOURS; i++) {
        if (t->n[i].used && memcmp(t->n[i].ap, ap, 6) == 0) t->n[i].bad_until_ms = now_ms + (int64_t)ms;
    }
}

void siot_path_mark_bad(siot_path_table_t *t, int64_t now_ms, const uint8_t ap[6])
{
    siot_path_mark_bad_for(t, now_ms, ap, SIOT_PATH_BAD_MS);
}

void siot_path_parent_lost(siot_path_table_t *t, int64_t now_ms, const uint8_t ap[6])
{
    memcpy(t->lost_ap, ap, 6);
    t->lost_at_ms = now_ms;
    t->lost_until_ms = now_ms + SIOT_PATH_LOST_MS;
}

bool siot_path_parent_complete(const siot_path_table_t *t, int64_t now_ms)
{
    if (!t->has_parent) return false;
    const siot_path_neighbour_t *p = siot_path_find_ap(t, t->parent_ap);
    return siot_path_fresh(p, now_ms) && p->complete;
}

bool siot_path_parent_held(const siot_path_table_t *t, int64_t now_ms)
{
    if (!t->has_parent) return false;
    const siot_path_neighbour_t *p = siot_path_find_ap(t, t->parent_ap);
    return siot_path_fresh(p, now_ms) && p->held && !p->complete;
}
