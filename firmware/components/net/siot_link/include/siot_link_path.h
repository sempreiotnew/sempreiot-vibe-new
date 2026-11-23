/* siot_link_path — which parent gives this unit the best PATH (blueprint §4,
 * protocol §7.16 PATH_ADVERT, v3.12).
 *
 * Mesh-Lite chooses a parent once, when the unit joins, and by the signal of
 * that one hop. A unit that joined the root at -85 dBm stayed there for good,
 * and the units under it, which heard it at -50, never knew their path had a
 * -85 link in it (building, 2026-11-16). So every mains unit in the mesh says,
 * on ESP-NOW, every SIOT_PATH_ADVERT_MS:
 *
 *     "this is my access point, my level, and the WEAKEST link between the
 *      root and me is X dBm — and these are the units above me"
 *
 * and every unit that hears it measures how well it arrived. The path a unit
 * would have through a neighbour is the weaker of the two numbers (how it
 * hears the neighbour, what the neighbour says of its own path). When another
 * path is clearly better than the one it has, for long enough, the unit moves
 * by itself (link_mesh_node.c pins the parent it chose in Mesh-Lite).
 *
 * This file is the arithmetic only — no radio, no clock of its own: tested on
 * the host (test/host test_path.c).
 */
#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ---- the rules ----------------------------------------------------------- */

/* A path at or above this is left alone. Moving a unit takes its branch off
 * the air for some seconds; it is done for a path that needs it, never to
 * polish one that works. -80 by the owner's word (2026-11-16; it was the
 * survey's green, -75): only units BELOW -80 are reorganised. */
#define SIOT_PATH_GOOD_DBM      (-80)
/* The other path must be this much better than the one the unit has. It also
 * covers what one number cannot say: a neighbour's frame is heard in ONE
 * direction, and a signal moves a few dB by itself. */
#define SIOT_PATH_GAIN_DB        10
/* ...and this much is enough for SIOT_PATH_JOIN_MS after the unit attached to
 * a parent it did not choose by its path — the library's join, or the way out
 * of "no path" (building, 2026-11-16: after a power cut the units come back
 * in any order, and each takes the first one it hears, or the only one with a
 * path so far). Still only below SIOT_PATH_GOOD_DBM, still for the whole
 * SIOT_PATH_SUSTAIN_MS, and the move it leads to starts the usual hold. */
#define SIOT_PATH_JOIN_GAIN_DB    5
/* RELAXED FOR THE BENCH (docs/ota/before-production.md item 11, requested
 * 2026-11-16): with 1 the three waits below are one minute each, so a move
 * can be watched without a quarter of an hour of waiting. 0 in production —
 * ci/check.sh --release fails while it is 1. */
#define SIOT_PATH_BENCH_TIMES 1
#if SIOT_PATH_BENCH_TIMES
#define SIOT_PATH_SUSTAIN_MS   60000
#define SIOT_PATH_QUIET_MS     60000
#define SIOT_PATH_HOLD_MS      60000
#define SIOT_PATH_HOLD_MAX_MS 480000
#define SIOT_PATH_JOIN_MS     180000
#else
/* ...and stay so for this long before the unit moves. */
#define SIOT_PATH_SUSTAIN_MS  180000
/* No COMMAND seen for this long (siot_netcore): nobody is working on the
 * installation. */
#define SIOT_PATH_QUIET_MS    600000
/* No other move for this long after one; doubles each move up to the max. */
#define SIOT_PATH_HOLD_MS     600000
#define SIOT_PATH_HOLD_MAX_MS 4800000
/* How long after such a join the smaller gain is enough. */
#define SIOT_PATH_JOIN_MS     600000
#endif
/* A neighbour counts once SIOT_PATH_MIN_HEARD of its adverts were heard with
 * no gap longer than SIOT_PATH_FRESH_MS (4 missed adverts). */
#define SIOT_PATH_ADVERT_MS   10000
#define SIOT_PATH_FRESH_MS    45000
#define SIOT_PATH_MIN_HEARD       3
/* A parent the unit could not attach to in a move to a BETTER path is not
 * tried again for this long. */
#define SIOT_PATH_BAD_MS    1800000
/* The same, for a unit with NO path (2026-11-23): it has few ways in, often
 * one, and half an hour without it left a far unit offline for hours. The
 * parent it missed is passed over for one round only. */
#define SIOT_PATH_RESCUE_SKIP_MS 30000
/* After this unit's parent was lost, or led nowhere, the units that hang from
 * that parent are not believed for this long: they go on saying COMPLETE
 * until the news reaches them, one advert per level. */
#define SIOT_PATH_LOST_MS     60000

/* The root's own path: there is no link between the root and itself. */
#define SIOT_PATH_ROOT_DBM        0
/* Deepest level a parent may have: its child is one deeper, and 15 is as deep
 * as the mesh goes (link_mesh_node.c, MESH_MAX_LEVEL). */
#define SIOT_PATH_MAX_PARENT_LEVEL 14

#define SIOT_PATH_NEIGHBOURS     24
#define SIOT_PATH_MAX_CHAIN      14 /* the units above a unit at the deepest level */

/* ---- PATH_ADVERT payload (protocol §7.16) --------------------------------- */

#define SIOT_PATH_ADVERT_VER      1
#define SIOT_PATH_F_COMPLETE   0x01 /* CHAIN reaches the root and PATH counts every link down to this unit */
#define SIOT_PATH_F_FULL       0x02 /* its access point takes no more units */
/* Bits 2..4, ALARM: 0 = no alarm known; 1 = this unit is in alarm; n = a unit
 * in alarm is n-1 radio hops from this one. Nobody moves while it is not 0
 * (the alarm's frames, and the ones that follow, need every path as it is).
 * A unit says the smallest number it hears plus one, up to
 * SIOT_PATH_ALARM_MAX, so the word dies by itself when its source stops. */
#define SIOT_PATH_F_ALARM_SHIFT   2
#define SIOT_PATH_F_ALARM_MASK 0x1C
#define SIOT_PATH_ALARM_MAX       7
/* Bit 5, HELD (v3.14, 2026-11-23): this unit has no path to the central
 * because the CENTRAL is not there — it is the root that had its session with
 * the board and lost it (the board is off), or its chain ends at that root.
 * The tree is whole: a unit that says or hears HELD from its parent stays
 * where it is and does not restart itself. Never together with COMPLETE. */
#define SIOT_PATH_F_HELD       0x20
#define SIOT_PATH_ADVERT_MIN_LEN 11
#define SIOT_PATH_ADVERT_MAX_LEN (SIOT_PATH_ADVERT_MIN_LEN + 6 * SIOT_PATH_MAX_CHAIN)

typedef struct {
    uint8_t level;      /* 1 = the root */
    bool    complete;
    bool    full;
    uint8_t alarm;      /* 0, or 1..SIOT_PATH_ALARM_MAX (SIOT_PATH_F_ALARM_MASK) */
    bool    held;       /* SIOT_PATH_F_HELD */
    int8_t  path;       /* dBm: the weakest unit-to-unit link from the root to this unit */
    uint8_t ap[6];      /* its access point's address: what a child attaches to */
    uint8_t chain_n;    /* the access points above it, its parent first */
    uint8_t chain[SIOT_PATH_MAX_CHAIN][6];
} siot_path_advert_t;

/* Returns the payload length, 0 when `cap` is too small or chain_n too big. */
size_t siot_path_advert_encode(const siot_path_advert_t *a, uint8_t *out, size_t cap);
/* False for a payload that is too short, of another version or cut. */
bool   siot_path_advert_decode(const uint8_t *p, size_t len, siot_path_advert_t *out);

/* ---- the neighbours ------------------------------------------------------- */

typedef struct {
    bool     used;
    uint8_t  id[6];        /* the unit's own address (SAFR SRC_MAC): its SSID suffix is made of it */
    uint8_t  ap[6];
    int16_t  rssi_q4;      /* how its adverts are heard, dBm x 16, smoothed */
    uint8_t  heard;        /* adverts in a row with no gap over SIOT_PATH_FRESH_MS */
    int64_t  last_ms;
    uint16_t boot_ctr;     /* its last frame: an older one is a replay */
    uint32_t msg_ctr;
    uint8_t  level;
    int8_t   path;
    bool     complete;
    bool     full;
    uint8_t  alarm;        /* what it last said (SIOT_PATH_F_ALARM_MASK) */
    bool     held;         /* what it last said (SIOT_PATH_F_HELD) */
    bool     under_me;     /* this unit is in its chain: it hangs from us */
    int64_t  bad_until_ms; /* 0 = never refused us */
    uint8_t  chain_n;      /* the access points above it, as it last said */
    uint8_t  chain[SIOT_PATH_MAX_CHAIN][6];
} siot_path_neighbour_t;

typedef struct {
    uint8_t  self_ap[6];
    siot_path_neighbour_t n[SIOT_PATH_NEIGHBOURS];
    /* The parent, and what it last said is above it. */
    bool     has_parent;
    uint8_t  parent_ap[6];
    uint8_t  parent_chain_n;
    uint8_t  parent_chain[SIOT_PATH_MAX_CHAIN][6];
    /* The link to the parent, dBm x 16, smoothed (siot_path_link_sample). */
    bool     link_known;
    int16_t  link_q4;
    /* Since when another path has been clearly better (0 = it is not). */
    int64_t  better_since_ms;
    /* The parent this unit lost, or left because nothing came down from it
     * (siot_path_parent_lost): until lost_until_ms the units that hang from
     * it are no way out. 0 = none. */
    uint8_t  lost_ap[6];
    int64_t  lost_at_ms;
    int64_t  lost_until_ms;
} siot_path_table_t;

void siot_path_init(siot_path_table_t *t, const uint8_t self_ap[6]);

/* One advert heard at `rssi`. Returns false when it was dropped: our own, a
 * replay, or no room (every entry fresher than this one would be). */
bool siot_path_heard(siot_path_table_t *t, int64_t now_ms, const uint8_t id[6], uint16_t boot_ctr,
                     uint32_t msg_ctr, int8_t rssi, const siot_path_advert_t *a);

/* Who the parent is now (NULL = none: not attached, or attached to the board).
 * A new parent forgets the old one's chain and the smoothed link. */
void siot_path_set_parent(siot_path_table_t *t, const uint8_t parent_ap[6]);
/* The station's signal to the parent, once per SIOT_PATH_ADVERT_MS. */
void siot_path_link_sample(siot_path_table_t *t, int8_t rssi);

const siot_path_neighbour_t *siot_path_find_ap(const siot_path_table_t *t, const uint8_t ap[6]);
/* Heard often and recently enough to be believed. */
bool   siot_path_fresh(const siot_path_neighbour_t *n, int64_t now_ms);
int8_t siot_path_rssi(const siot_path_neighbour_t *n);

/* What this unit says of itself. `root`: attached to the board; `root_proven`:
 * and its session with the board is open. `level` is the mesh level (root =
 * 1). A child's path is the weaker of its link and its parent's path; it is
 * COMPLETE only when its parent's fresh advert was. */
void siot_path_own(const siot_path_table_t *t, int64_t now_ms, uint8_t level, bool root, bool root_proven,
                   bool full, siot_path_advert_t *out);

typedef struct {
    uint8_t id[6];
    uint8_t ap[6];
    uint8_t level;      /* the parent's: this unit would be one deeper */
    int8_t  rssi;       /* how the parent is heard */
    int8_t  path_new;   /* the path through it */
    int8_t  path_now;   /* the path this unit has */
} siot_path_choice_t;

/* The best other parent, whatever the gain: fills `out` and returns true when
 * one can be compared at all (this unit has a parent and knows its link; a
 * neighbour is fresh, complete, not full, not under this unit, not refused
 * lately, not the parent, not too deep). For the log. */
bool siot_path_best(const siot_path_table_t *t, int64_t now_ms, siot_path_choice_t *out);

/* For a unit with NO path to the central — the root's role held without the
 * board, or a parent nothing comes down from: the best neighbour that says it
 * has a real path (COMPLETE: its chain ends at a root with its session to the
 * board), whatever the signals — any path beats none. `path_now` is -128.
 * A unit that hangs from the parent this one just lost is passed over
 * (siot_path_parent_lost). False when nobody in reach has one: there is
 * nothing to join. */
bool siot_path_rescue(const siot_path_table_t *t, int64_t now_ms, siot_path_choice_t *out);

/* Called once per SIOT_PATH_ADVERT_MS while the unit may move. True when the
 * path through `out` has been `gain_db` (SIOT_PATH_GAIN_DB, or
 * SIOT_PATH_JOIN_GAIN_DB) better than a path below SIOT_PATH_GOOD_DBM for
 * `sustain_ms` in a row: the unit should move now. */
bool siot_path_evaluate(siot_path_table_t *t, int64_t now_ms, uint32_t sustain_ms, int8_t gain_db,
                        siot_path_choice_t *out);

/* The ALARM number this unit says: 1 when `own` (it is in alarm), else one
 * more than the smallest heard in the last SIOT_PATH_FRESH_MS, 0 when none is
 * heard or it is already SIOT_PATH_ALARM_MAX hops away. Not 0 = no move. */
uint8_t siot_path_alarm(const siot_path_table_t *t, int64_t now_ms, bool own);
/* The unit may not move now (alarm, update, just moved): the wait starts over. */
void siot_path_evaluate_reset(siot_path_table_t *t);

/* The unit could not attach to that parent: not again for SIOT_PATH_BAD_MS. */
void siot_path_mark_bad(siot_path_table_t *t, int64_t now_ms, const uint8_t ap[6]);
/* The same, for `ms` (SIOT_PATH_RESCUE_SKIP_MS for a unit with no path). */
void siot_path_mark_bad_for(siot_path_table_t *t, int64_t now_ms, const uint8_t ap[6], uint32_t ms);

/* The parent at `ap` was lost, or nothing of the central comes down from it:
 * for SIOT_PATH_LOST_MS siot_path_rescue passes over it and every unit whose
 * chain goes through it — until that parent itself is heard again saying
 * COMPLETE, which ends the wait at once. */
void siot_path_parent_lost(siot_path_table_t *t, int64_t now_ms, const uint8_t ap[6]);

/* The parent's fresh advert says COMPLETE: it vouches for a path. */
bool siot_path_parent_complete(const siot_path_table_t *t, int64_t now_ms);
/* The parent's fresh advert says HELD (SIOT_PATH_F_HELD). */
bool siot_path_parent_held(const siot_path_table_t *t, int64_t now_ms);

#ifdef __cplusplus
}
#endif
