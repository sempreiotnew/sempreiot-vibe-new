/* Protocol §7.3 DL_HEARD (v3.6): board heartbeats heard in the last 120 s;
 * DL_MAP (v3.7): which of the last 8 slots were heard. */
#include "unity.h"

#include "siot_hbwin.h"

/* The board's beats: at `i * 15 s` on our clock, UPTIME_S = 100 + 15 i. */
static void beat(siot_hbwin_t *w, int i) { siot_hbwin_note(w, (int64_t)i * 15000, 100u + 15u * (uint32_t)i); }

TEST_CASE("hbwin: nothing to say for the first 120 s in the mesh", "[hbwin]")
{
    siot_hbwin_t w;
    siot_hbwin_init(&w, 1000);
    for (int i = 0; i < 7; i++) siot_hbwin_note(&w, 1000 + i * 15000, 15u * (uint32_t)i);
    TEST_ASSERT_EQUAL_UINT8(SIOT_HBWIN_NA, siot_hbwin_heard(&w, 1000 + 119999));
    TEST_ASSERT_EQUAL_UINT8(0, siot_hbwin_map(&w, 1000 + 119999));
    /* At 120 s the one that opened the window is exactly 120 s old: outside. */
    TEST_ASSERT_EQUAL_UINT8(6, siot_hbwin_heard(&w, 1000 + 120000));
}

TEST_CASE("hbwin: a healthy link reads 8 of 8, a lossy one what it heard", "[hbwin]")
{
    siot_hbwin_t w;
    siot_hbwin_init(&w, 0);
    /* 20 heartbeats at 15 s; the window only ever sees the last 8. */
    for (int i = 0; i < 20; i++) beat(&w, i);
    TEST_ASSERT_EQUAL_UINT8(8, siot_hbwin_heard(&w, 19 * 15000 + 1));
    TEST_ASSERT_EQUAL_UINT8(0xFF, siot_hbwin_map(&w, 19 * 15000 + 1));
    /* Then the board goes quiet for a minute: 4 of the last 8 are gone. */
    TEST_ASSERT_EQUAL_UINT8(4, siot_hbwin_heard(&w, 19 * 15000 + 60001));
    /* 60 s late: 3 beats overdue (at 20, 35, 50 s), the 4th not yet. */
    TEST_ASSERT_EQUAL_UINT8(0xF8, siot_hbwin_map(&w, 19 * 15000 + 60001));
    /* Two minutes of silence: 0 — the map still grants the 8th beat its
     * 5 s of lateness (bit 7 is the last one heard), then every slot is lost. */
    TEST_ASSERT_EQUAL_UINT8(0, siot_hbwin_heard(&w, 19 * 15000 + 120001));
    TEST_ASSERT_EQUAL_UINT8(0x80, siot_hbwin_map(&w, 19 * 15000 + 120001));
    TEST_ASSERT_EQUAL_UINT8(0, siot_hbwin_map(&w, 19 * 15000 + 125001));
}

TEST_CASE("hbwin: jitter never reads more than 8, a re-join starts over", "[hbwin]")
{
    siot_hbwin_t w;
    siot_hbwin_init(&w, 0);
    for (int i = 0; i < 9; i++) siot_hbwin_note(&w, i * 13000, 13u * (uint32_t)i); /* 9 in 117 s */
    TEST_ASSERT_EQUAL_UINT8(8, siot_hbwin_heard(&w, 120000));
    siot_hbwin_init(&w, 200000);
    TEST_ASSERT_EQUAL_UINT8(SIOT_HBWIN_NA, siot_hbwin_heard(&w, 200000 + 1000));
    TEST_ASSERT_EQUAL_UINT8(0, siot_hbwin_heard(&w, 200000 + 120000));
    TEST_ASSERT_EQUAL_UINT8(0, siot_hbwin_map(&w, 200000 + 120000));
}

TEST_CASE("hbwin map: a lost beat is a 0 where the board's clock says it was", "[hbwin]")
{
    siot_hbwin_t w;
    siot_hbwin_init(&w, 0);
    for (int i = 0; i < 10; i++) {
        if (i == 7) continue; /* the 8th beat never arrives */
        beat(&w, i);
    }
    /* Read right after beat 9: slots 9 (bit 0), 8 (bit 1), 7 lost (bit 2), 6..2 heard. */
    TEST_ASSERT_EQUAL_UINT8(0xFB, siot_hbwin_map(&w, 9 * 15000 + 1));
    TEST_ASSERT_EQUAL_UINT8(7, siot_hbwin_heard(&w, 9 * 15000 + 1));
    /* Two in a row lost (10 and 11), then 12 arrives: 0b1001 1111 -> wait, the map
     * is newest first: 12 heard (bit 0), 11 lost, 10 lost, 9 heard, 8 heard, 7 lost, 6, 5. */
    beat(&w, 12);
    TEST_ASSERT_EQUAL_UINT8(0xD9, siot_hbwin_map(&w, 12 * 15000 + 1));
    /* A 16 s gap (the board's loop drifts) is still one slot, nothing lost. */
    siot_hbwin_note(&w, 13 * 15000 + 1000, 100u + 15u * 13u + 1u);
    TEST_ASSERT_EQUAL_UINT8(0xB3, siot_hbwin_map(&w, 13 * 15000 + 1001));
}

TEST_CASE("hbwin map: an extra beat shares its slot, a board reboot starts a new run", "[hbwin]")
{
    siot_hbwin_t w;
    siot_hbwin_init(&w, 0);
    for (int i = 0; i < 9; i++) beat(&w, i);
    TEST_ASSERT_EQUAL_UINT8(0xFF, siot_hbwin_map(&w, 8 * 15000 + 1));
    /* The link-up beat 2 s after the regular one: same slot, still 8 heard. */
    siot_hbwin_note(&w, 8 * 15000 + 2000, 100u + 15u * 8u + 2u);
    TEST_ASSERT_EQUAL_UINT8(0xFF, siot_hbwin_map(&w, 8 * 15000 + 2001));
    /* The board reboots: its uptime starts over; the map goes on from this beat. */
    siot_hbwin_note(&w, 9 * 15000, 3u);
    TEST_ASSERT_EQUAL_UINT8(0xFF, siot_hbwin_map(&w, 9 * 15000 + 1));
    /* Overdue at read time: 21 s after the last beat the newest slot is lost. */
    TEST_ASSERT_EQUAL_UINT8(0xFE, siot_hbwin_map(&w, 9 * 15000 + 21000));
    /* …and when that beat does arrive late (gap 30 s by the board's clock) the
     * map agrees with what the read said: one lost between. */
    siot_hbwin_note(&w, 11 * 15000, 3u + 30u);
    TEST_ASSERT_EQUAL_UINT8(0xFD, siot_hbwin_map(&w, 11 * 15000 + 1));
}
