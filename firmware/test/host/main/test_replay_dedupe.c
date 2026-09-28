/* Spec §4 replay protection and §9.1 dedupe, on the RX pipeline. The sender
 * is a second siot_safr "instance" emulated by building frames with explicit
 * counters through the codec (same key, same SYSTEM_ID). */
#include <string.h>

#include "unity.h"

#include "siot_safr.h"
#include "test_support.h"

static int  s_calls, s_dups;
static void count(const siot_safr_frame_t *f, const uint8_t *raw, size_t raw_len,
                  bool duplicate, void *ctx)
{
    (void)f; (void)raw; (void)raw_len; (void)ctx;
    s_calls++;
    if (duplicate) s_dups++;
}

/* A HEARTBEAT from TV_SRC_MAC with the given counters. */
static size_t hb(uint8_t *out, uint16_t msg_id, uint16_t boot_ctr, uint32_t msg_ctr)
{
    uint8_t p[20] = {0};
    p[19] = 1;
    return siot_safr_build_frame(out, SAFR_MSG_HEARTBEAT, msg_id, TV_SRC_MAC, SAFR_BCAST_MAC,
                                 6, 1, 0, boot_ctr, msg_ctr, p, sizeof(p));
}

static void setup(void)
{
    ts_safr_init(TS_OTHER_MAC, 1);
    ts_clock_set(10000);
    s_calls = s_dups = 0;
    TEST_ASSERT_EQUAL(ESP_OK, siot_safr_register(SAFR_MSG_HEARTBEAT, count, NULL));
}

TEST_CASE("replay: identical frame twice -> second is REPLAY, not dispatched", "[safr][replay]")
{
    setup();
    uint8_t f[SAFR_MAX_FRAME];
    const size_t n = hb(f, 10, 3, 100);

    TEST_ASSERT_EQUAL(SIOT_SAFR_RX_OK, siot_safr_rx(f, n));
    TEST_ASSERT_EQUAL(SIOT_SAFR_RX_REPLAY, siot_safr_rx(f, n));
    TEST_ASSERT_EQUAL(1, s_calls);

    siot_safr_stats_t st;
    siot_safr_get_stats(&st);
    TEST_ASSERT_EQUAL(1, st.replay);
    TEST_ASSERT_EQUAL(1, st.rx_ok);
    TEST_ASSERT_EQUAL(0, st.dup);
    siot_safr_unregister(SAFR_MSG_HEARTBEAT);
}

TEST_CASE("replay: older MSG_CTR from the same boot is REPLAY; new boot restarts", "[safr][replay]")
{
    setup();
    uint8_t f[SAFR_MAX_FRAME];
    size_t n;

    n = hb(f, 11, 3, 200);
    TEST_ASSERT_EQUAL(SIOT_SAFR_RX_OK, siot_safr_rx(f, n));

    n = hb(f, 12, 3, 150); /* captured earlier, replayed now */
    TEST_ASSERT_EQUAL(SIOT_SAFR_RX_REPLAY, siot_safr_rx(f, n));

    n = hb(f, 12, 3, 200); /* equal counter, different MSG_ID: still a replay */
    TEST_ASSERT_EQUAL(SIOT_SAFR_RX_REPLAY, siot_safr_rx(f, n));

    n = hb(f, 13, 3, 201);
    TEST_ASSERT_EQUAL(SIOT_SAFR_RX_OK, siot_safr_rx(f, n));

    /* Device rebooted: BOOT_CTR 4, MSG_CTR back to 1 — accepted. */
    n = hb(f, 1, 4, 1);
    TEST_ASSERT_EQUAL(SIOT_SAFR_RX_OK, siot_safr_rx(f, n));

    /* And a late frame from boot 3 is now a different boot: accepted (the
     * app does the same — only "same boot, counter not newer" is a replay). */
    n = hb(f, 14, 3, 202);
    TEST_ASSERT_EQUAL(SIOT_SAFR_RX_OK, siot_safr_rx(f, n));

    TEST_ASSERT_EQUAL(4, s_calls);
    siot_safr_unregister(SAFR_MSG_HEARTBEAT);
}

TEST_CASE("replay: counters are tracked per SRC_MAC", "[safr][replay]")
{
    setup();
    uint8_t f[SAFR_MAX_FRAME];
    const uint8_t other[6] = {0x5A, 0x46, 0x52, 0x00, 0x00, 0x02};
    uint8_t p[20] = {0};
    size_t n;

    n = hb(f, 1, 1, 50);
    TEST_ASSERT_EQUAL(SIOT_SAFR_RX_OK, siot_safr_rx(f, n));
    /* A second device at a lower counter is not a replay of the first. */
    n = siot_safr_build_frame(f, SAFR_MSG_HEARTBEAT, 1, other, SAFR_BCAST_MAC, 6, 1, 0, 1, 10, p, 20);
    TEST_ASSERT_EQUAL(SIOT_SAFR_RX_OK, siot_safr_rx(f, n));
    n = siot_safr_build_frame(f, SAFR_MSG_HEARTBEAT, 2, other, SAFR_BCAST_MAC, 6, 1, 0, 1, 10, p, 20);
    TEST_ASSERT_EQUAL(SIOT_SAFR_RX_REPLAY, siot_safr_rx(f, n));
    n = hb(f, 2, 1, 51);
    TEST_ASSERT_EQUAL(SIOT_SAFR_RX_OK, siot_safr_rx(f, n));
    siot_safr_unregister(SAFR_MSG_HEARTBEAT);
}

TEST_CASE("dedupe: fast retry (same MSG_ID, fresh MSG_CTR) -> handler sees duplicate=true", "[safr][dedupe]")
{
    setup();
    uint8_t f[SAFR_MAX_FRAME];
    size_t n;

    n = hb(f, 20, 1, 300);
    TEST_ASSERT_EQUAL(SIOT_SAFR_RX_OK, siot_safr_rx(f, n));
    TEST_ASSERT_EQUAL(1, s_calls);
    TEST_ASSERT_EQUAL(0, s_dups);

    ts_clock_advance(2000); /* RETRY_BACKOFF_MS */
    n = hb(f, 20, 1, 301);  /* retransmission: same MSG_ID, fresh MSG_CTR */
    TEST_ASSERT_EQUAL(SIOT_SAFR_RX_DUPLICATE, siot_safr_rx(f, n));
    TEST_ASSERT_EQUAL(2, s_calls);   /* handler is called so it can ACK... */
    TEST_ASSERT_EQUAL(1, s_dups);    /* ...but told not to process again */

    ts_clock_advance(2000);
    n = hb(f, 20, 1, 302);
    TEST_ASSERT_EQUAL(SIOT_SAFR_RX_DUPLICATE, siot_safr_rx(f, n));
    TEST_ASSERT_EQUAL(2, s_dups);

    /* A new MSG_ID is a new message. */
    n = hb(f, 21, 1, 303);
    TEST_ASSERT_EQUAL(SIOT_SAFR_RX_OK, siot_safr_rx(f, n));

    siot_safr_stats_t st;
    siot_safr_get_stats(&st);
    TEST_ASSERT_EQUAL(2, st.rx_ok);
    TEST_ASSERT_EQUAL(2, st.dup);
    TEST_ASSERT_EQUAL(0, st.replay);
    siot_safr_unregister(SAFR_MSG_HEARTBEAT);
}

TEST_CASE("dedupe: entries expire after the 30 s window", "[safr][dedupe]")
{
    setup();
    uint8_t f[SAFR_MAX_FRAME];
    size_t n;

    n = hb(f, 30, 1, 400);
    TEST_ASSERT_EQUAL(SIOT_SAFR_RX_OK, siot_safr_rx(f, n));

    ts_clock_advance(CONFIG_SIOT_SAFR_DEDUP_TTL_MS); /* exactly at the window: still inside */
    n = hb(f, 30, 1, 401);
    TEST_ASSERT_EQUAL(SIOT_SAFR_RX_DUPLICATE, siot_safr_rx(f, n));

    ts_clock_advance(CONFIG_SIOT_SAFR_DEDUP_TTL_MS + 1); /* the refreshed entry has aged out */
    n = hb(f, 30, 1, 402);
    TEST_ASSERT_EQUAL(SIOT_SAFR_RX_OK, siot_safr_rx(f, n));
    siot_safr_unregister(SAFR_MSG_HEARTBEAT);
}

TEST_CASE("dedupe: is per SRC_MAC and survives table pressure", "[safr][dedupe]")
{
    setup();
    uint8_t f[SAFR_MAX_FRAME];
    uint8_t p[20] = {0};
    size_t n;

    /* Same MSG_ID from two devices: two messages. */
    const uint8_t other[6] = {0x5A, 0x46, 0x52, 0x00, 0x00, 0x03};
    n = hb(f, 40, 1, 500);
    TEST_ASSERT_EQUAL(SIOT_SAFR_RX_OK, siot_safr_rx(f, n));
    n = siot_safr_build_frame(f, SAFR_MSG_HEARTBEAT, 40, other, SAFR_BCAST_MAC, 6, 1, 0, 1, 1, p, 20);
    TEST_ASSERT_EQUAL(SIOT_SAFR_RX_OK, siot_safr_rx(f, n));

    /* Fill the table past capacity with distinct MSG_IDs: the oldest entry
     * (MSG_ID 40 from TV_SRC_MAC) is evicted, later ones are still deduped. */
    for (uint16_t id = 100; id < 100 + CONFIG_SIOT_SAFR_DEDUP_CAP; id++) {
        ts_clock_advance(10);
        n = hb(f, id, 1, 600 + id);
        TEST_ASSERT_EQUAL(SIOT_SAFR_RX_OK, siot_safr_rx(f, n));
    }
    n = hb(f, 100 + CONFIG_SIOT_SAFR_DEDUP_CAP - 1, 1, 900);
    TEST_ASSERT_EQUAL(SIOT_SAFR_RX_DUPLICATE, siot_safr_rx(f, n));
    n = hb(f, 40, 1, 901);
    TEST_ASSERT_EQUAL(SIOT_SAFR_RX_OK, siot_safr_rx(f, n)); /* evicted -> looks new (bounded table) */
    siot_safr_unregister(SAFR_MSG_HEARTBEAT);
}
