/* siot_hbwin — "how many of the board's HEARTBEATs did this node hear?"
 *
 * The board sends one HEARTBEAT down the mesh every 15 s (protocol §7.3);
 * each hop is a single broadcast with no retry, so the ones a node misses
 * are the truest measure of its downlink. A node keeps the times of the
 * last ones heard and reports, in its own HEARTBEAT (§7.3 DL_HEARD, v3.6),
 * how many arrived in the last 120 s — 8 expected.
 *
 * v3.7 (2026-10-27) adds WHICH ones: DL_MAP, a bitmap of the last 8 beat
 * slots, bit 0 the most recent, 1 = heard, 0 = lost. The slots come from
 * the board's UPTIME_S in the beats that did arrive: the board's beats are
 * 15 s apart, so a 30 s jump between two heard beats is one lost beat in
 * between. The map also advances at read time when a beat is overdue (no
 * beat for 20 s = the newest slot is lost), so a node that stops hearing
 * the board reports it without waiting for the next beat.
 *
 * Pure C, no IDF: host-tested (test/host/main/test_hbwin.c).
 */
#pragma once
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define SIOT_HBWIN_SPAN_MS   120000 /* 8 board heartbeats at 15 s */
#define SIOT_HBWIN_EXPECTED  8
#define SIOT_HBWIN_NA        0xFF   /* less than SPAN in the mesh: nothing to say yet */
#define SIOT_HBWIN_PERIOD_S  15     /* the board's heartbeat cadence (siot_coordinator.c) */
#define SIOT_HBWIN_LATE_MS   5000   /* a beat this late is still "on time" */

typedef struct {
    int64_t heard_ms[SIOT_HBWIN_EXPECTED * 2]; /* ring: a jittery board may fit 9 in a span */
    uint8_t next;
    uint8_t count;
    int64_t since_ms;                           /* when the window started (join / re-join) */
    /* DL_MAP (v3.7) */
    uint8_t  map;            /* bit 0 = the latest beat slot; 1 heard, 0 lost */
    bool     have_uptime;    /* a beat with its UPTIME_S was heard in this window */
    uint32_t last_uptime_s;  /* the board's UPTIME_S in the last beat heard */
    int64_t  last_heard_ms;  /* when it arrived */
} siot_hbwin_t;

/* Start (or restart, on a level change) the window at `now`. */
void siot_hbwin_init(siot_hbwin_t *w, int64_t now_ms);

/* A board HEARTBEAT arrived (the first copy of it, not a duplicate), carrying
 * the board's UPTIME_S (§7.3 offset 4). */
void siot_hbwin_note(siot_hbwin_t *w, int64_t now_ms, uint32_t board_uptime_s);

/* Board heartbeats heard in the last SPAN, capped at EXPECTED; NA until the
 * window is SPAN old. */
uint8_t siot_hbwin_heard(const siot_hbwin_t *w, int64_t now_ms);

/* DL_MAP: the last 8 beat slots, bit 0 the most recent, 1 = heard. Slots a
 * beat is overdue for (> PERIOD + LATE since the last heard) read as lost.
 * 0 while `siot_hbwin_heard` is NA (the receiver ignores it then). */
uint8_t siot_hbwin_map(const siot_hbwin_t *w, int64_t now_ms);

#ifdef __cplusplus
}
#endif
