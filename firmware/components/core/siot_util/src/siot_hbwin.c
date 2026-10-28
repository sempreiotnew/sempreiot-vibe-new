#include "siot_hbwin.h"

#include <string.h>

void siot_hbwin_init(siot_hbwin_t *w, int64_t now_ms)
{
    memset(w, 0, sizeof(*w));
    w->since_ms = now_ms;
}

void siot_hbwin_note(siot_hbwin_t *w, int64_t now_ms, uint32_t board_uptime_s)
{
    const uint8_t cap = (uint8_t)(sizeof(w->heard_ms) / sizeof(w->heard_ms[0]));
    w->heard_ms[w->next] = now_ms;
    w->next = (uint8_t)((w->next + 1) % cap);
    if (w->count < cap) w->count++;

    /* DL_MAP: place this beat by the board's own clock. */
    if (!w->have_uptime) {
        w->map = (uint8_t)((w->map << 1) | 1u);
    } else {
        const int64_t gap = (int64_t)board_uptime_s - (int64_t)w->last_uptime_s;
        if (gap > -(SIOT_HBWIN_PERIOD_S / 2) && gap < SIOT_HBWIN_PERIOD_S / 2) {
            /* An extra beat in the same slot (the board sends one on a
             * link-up, siot_coordinator.c on_link): heard, no new slot. */
            w->map |= 1u;
        } else if (gap < 0) {
            /* The board rebooted: a new sequence starts with this beat. */
            w->map = (uint8_t)((w->map << 1) | 1u);
        } else {
            int lost = (int)((gap + SIOT_HBWIN_PERIOD_S / 2) / SIOT_HBWIN_PERIOD_S) - 1;
            if (lost < 0) lost = 0;
            if (lost > SIOT_HBWIN_EXPECTED) lost = SIOT_HBWIN_EXPECTED;
            w->map = (uint8_t)(((unsigned)w->map << (lost + 1)) | 1u);
        }
    }
    w->have_uptime = true;
    w->last_uptime_s = board_uptime_s;
    w->last_heard_ms = now_ms;
}

uint8_t siot_hbwin_heard(const siot_hbwin_t *w, int64_t now_ms)
{
    if (now_ms - w->since_ms < SIOT_HBWIN_SPAN_MS) return SIOT_HBWIN_NA;
    uint8_t n = 0;
    for (uint8_t i = 0; i < w->count; i++) {
        if (now_ms - w->heard_ms[i] < SIOT_HBWIN_SPAN_MS) n++;
    }
    return n > SIOT_HBWIN_EXPECTED ? SIOT_HBWIN_EXPECTED : n;
}

uint8_t siot_hbwin_map(const siot_hbwin_t *w, int64_t now_ms)
{
    if (now_ms - w->since_ms < SIOT_HBWIN_SPAN_MS) return 0;
    if (!w->have_uptime) return 0; /* nothing heard in a whole window: all lost */
    /* Beats that should have arrived since the last one heard. */
    const int64_t late = now_ms - w->last_heard_ms - SIOT_HBWIN_LATE_MS;
    int overdue = late > 0 ? (int)(late / (SIOT_HBWIN_PERIOD_S * 1000)) : 0;
    if (overdue > SIOT_HBWIN_EXPECTED) overdue = SIOT_HBWIN_EXPECTED;
    return (uint8_t)((unsigned)w->map << overdue);
}
