/* siot_link byte-stream reassembler (spec §10 steps 1–3): SOF + LEN + CRC,
 * discard exactly one byte on failure, frames split across chunks, boot
 * chatter before the first frame, a corrupted frame followed by a good one. */
#include <string.h>

#include "unity.h"

#include "siot_link.h"
#include "test_support.h"

static uint8_t s_got[4][SAFR_MAX_FRAME];
static size_t  s_got_len[4];
static int     s_got_n;
static siot_link_kind_t s_got_kind;

static void on_rx(siot_link_kind_t kind, const uint8_t *frame, size_t len, void *ctx)
{
    (void)ctx;
    TEST_ASSERT_TRUE(s_got_n < 4);
    memcpy(s_got[s_got_n], frame, len);
    s_got_len[s_got_n] = len;
    s_got_kind = kind;
    s_got_n++;
}

static size_t make_frame(uint8_t *out, uint16_t msg_id, uint8_t plen)
{
    uint8_t p[SAFR_MAX_PAYLOAD];
    for (int i = 0; i < plen; i++) p[i] = (uint8_t)i;
    return siot_safr_build_frame(out, SAFR_MSG_HEARTBEAT, msg_id, TV_SRC_MAC, SAFR_BCAST_MAC,
                                 7, 0, 0, 1, msg_id, p, plen);
}

static void setup(siot_link_reasm_t *r)
{
    ts_safr_init(TS_OTHER_MAC, 1);
    siot_link_set_rx(on_rx, NULL);
    siot_link_reasm_reset(r);
    s_got_n = 0;
}

TEST_CASE("reasm: whole frame, two frames in one chunk, frame split byte by byte", "[link]")
{
    siot_link_reasm_t r;
    setup(&r);
    uint8_t f1[SAFR_MAX_FRAME], f2[SAFR_MAX_FRAME], buf[2 * SAFR_MAX_FRAME];
    const size_t n1 = make_frame(f1, 1, 20), n2 = make_frame(f2, 2, 5);

    TEST_ASSERT_EQUAL(1, siot_link_reasm_feed(&r, SIOT_LINK_SERIAL, f1, n1));
    TEST_ASSERT_EQUAL(SIOT_LINK_SERIAL, s_got_kind);
    TEST_ASSERT_EQUAL(n1, s_got_len[0]);
    TEST_ASSERT_EQUAL_HEX8_ARRAY(f1, s_got[0], n1);

    memcpy(buf, f1, n1); memcpy(buf + n1, f2, n2);
    TEST_ASSERT_EQUAL(2, siot_link_reasm_feed(&r, SIOT_LINK_MESH, buf, n1 + n2));
    TEST_ASSERT_EQUAL(3, s_got_n);
    TEST_ASSERT_EQUAL_HEX8_ARRAY(f2, s_got[2], n2);

    s_got_n = 0;
    size_t delivered = 0;
    for (size_t i = 0; i < n2; i++) delivered += siot_link_reasm_feed(&r, SIOT_LINK_MESH, &f2[i], 1);
    TEST_ASSERT_EQUAL(1, delivered);
    TEST_ASSERT_EQUAL_HEX8_ARRAY(f2, s_got[0], n2);
    TEST_ASSERT_EQUAL(0, r.len); /* nothing left over */
}

TEST_CASE("reasm: boot chatter, false SOF and a corrupted frame cost one byte each", "[link]")
{
    siot_link_reasm_t r;
    setup(&r);
    uint8_t f1[SAFR_MAX_FRAME], bad[SAFR_MAX_FRAME], buf[3 * SAFR_MAX_FRAME];
    const size_t n1 = make_frame(f1, 7, 10);
    memcpy(bad, f1, n1);
    bad[n1 - 1] ^= 0x01; /* CRC wrong */

    /* ROM banner containing 0xA5 bytes and a plausible LEN, then a corrupted
     * frame, then the good one: only the good one comes out. */
    const uint8_t chatter[] = {'E', 'S', 'P', 0xA5, 0x03, 0x00, 0x30, 'x', 0xA5, 0x03, 0x00, 0x22, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00};
    size_t off = 0;
    memcpy(buf + off, chatter, sizeof(chatter)); off += sizeof(chatter);
    memcpy(buf + off, bad, n1); off += n1;
    memcpy(buf + off, f1, n1); off += n1;
    TEST_ASSERT_EQUAL(1, siot_link_reasm_feed(&r, SIOT_LINK_SERIAL, buf, off));
    TEST_ASSERT_EQUAL(1, s_got_n);
    TEST_ASSERT_EQUAL_HEX8_ARRAY(f1, s_got[0], n1);

    /* LEN out of bounds (> 250) is skipped without waiting for bytes. */
    setup(&r);
    const uint8_t huge[] = {0xA5, 0x03, 0x01, 0x00};
    TEST_ASSERT_EQUAL(0, siot_link_reasm_feed(&r, SIOT_LINK_SERIAL, huge, sizeof(huge)));
    TEST_ASSERT_EQUAL(1, siot_link_reasm_feed(&r, SIOT_LINK_SERIAL, f1, n1));

    /* Overflow guard: garbage beyond the accumulator resets it, then a frame still works. */
    setup(&r);
    uint8_t junk[2 * SAFR_MAX_FRAME];
    memset(junk, 0x11, sizeof(junk));
    TEST_ASSERT_EQUAL(0, siot_link_reasm_feed(&r, SIOT_LINK_SERIAL, junk, sizeof(junk)));
    TEST_ASSERT_EQUAL(0, siot_link_reasm_feed(&r, SIOT_LINK_SERIAL, junk, 10));
    TEST_ASSERT_EQUAL(1, siot_link_reasm_feed(&r, SIOT_LINK_SERIAL, f1, n1));
}

TEST_CASE("reasm: registry send/is_up report a missing backend", "[link]")
{
    uint8_t f[4] = {0};
    TEST_ASSERT_EQUAL(ESP_ERR_INVALID_STATE, siot_link_send(SIOT_LINK_SERIAL, SAFR_BCAST_MAC, f, 4));
    TEST_ASSERT_FALSE(siot_link_is_up(SIOT_LINK_MESH));
    TEST_ASSERT_EQUAL(ESP_ERR_INVALID_ARG, siot_link_register(SIOT_LINK_KIND_MAX, NULL));
}

/* ---- stream: a frame announces a raw run (protocol §13.3) ------------------------ */

static siot_link_stream_t s_st;
static uint8_t s_raw[64];
static size_t  s_raw_n;
static int     s_raw_done, s_raw_aborted;
static size_t  s_announce; /* on the 1st frame, expect this many raw bytes */

static void on_raw(const uint8_t *data, size_t len, size_t left, void *ctx)
{
    (void)ctx;
    if (data == NULL) { s_raw_aborted++; return; }
    TEST_ASSERT_TRUE(s_raw_n + len <= sizeof(s_raw));
    memcpy(s_raw + s_raw_n, data, len);
    s_raw_n += len;
    if (left == 0) s_raw_done++;
}

static void on_rx_announce(siot_link_kind_t kind, const uint8_t *frame, size_t len, void *ctx)
{
    on_rx(kind, frame, len, ctx);
    if (s_got_n == 1 && s_announce) {
        TEST_ASSERT_EQUAL(ESP_OK, siot_link_stream_expect_raw(&s_st, s_announce, on_raw, NULL));
        /* one run at a time */
        TEST_ASSERT_EQUAL(ESP_ERR_INVALID_STATE, siot_link_stream_expect_raw(&s_st, 1, on_raw, NULL));
    }
}

static void stream_setup(size_t announce)
{
    ts_safr_init(TS_OTHER_MAC, 1);
    siot_link_set_rx(on_rx_announce, NULL);
    siot_link_stream_reset(&s_st);
    s_got_n = 0;
    s_raw_n = 0;
    s_raw_done = s_raw_aborted = 0;
    s_announce = announce;
}

TEST_CASE("stream: raw bytes after a frame are data, even when they look like a frame", "[link][stream]")
{
    uint8_t f1[SAFR_MAX_FRAME], f2[SAFR_MAX_FRAME], buf[3 * SAFR_MAX_FRAME];
    stream_setup(40); /* first: the codec needs its key to build a frame */
    const size_t n1 = make_frame(f1, 1, 10), n2 = make_frame(f2, 2, 5);
    TEST_ASSERT_TRUE(n1 > 0 && n2 > 40);

    /* frame 1, then 40 raw bytes that are the start of a valid frame, then frame 2 — in ONE read */
    size_t off = 0;
    memcpy(buf + off, f1, n1); off += n1;
    memcpy(buf + off, f2, 40); off += 40;
    memcpy(buf + off, f2, n2); off += n2;
    siot_link_stream_feed(&s_st, SIOT_LINK_SERIAL, buf, off);
    TEST_ASSERT_EQUAL(2, s_got_n);
    TEST_ASSERT_EQUAL_HEX8_ARRAY(f1, s_got[0], n1);
    TEST_ASSERT_EQUAL_HEX8_ARRAY(f2, s_got[1], n2);
    TEST_ASSERT_EQUAL(1, s_raw_done);
    TEST_ASSERT_EQUAL(40, s_raw_n);
    TEST_ASSERT_EQUAL_HEX8_ARRAY(f2, s_raw, 40);

    /* the same bytes one at a time */
    stream_setup(40);
    for (size_t i = 0; i < off; i++) siot_link_stream_feed(&s_st, SIOT_LINK_SERIAL, &buf[i], 1);
    TEST_ASSERT_EQUAL(2, s_got_n);
    TEST_ASSERT_EQUAL(1, s_raw_done);
    TEST_ASSERT_EQUAL(40, s_raw_n);
    TEST_ASSERT_EQUAL_HEX8_ARRAY(f2, s_raw, 40);

    /* no run announced: two frames, nothing raw */
    stream_setup(0);
    memcpy(buf, f1, n1); memcpy(buf + n1, f2, n2);
    siot_link_stream_feed(&s_st, SIOT_LINK_SERIAL, buf, n1 + n2);
    TEST_ASSERT_EQUAL(2, s_got_n);
    TEST_ASSERT_EQUAL(0, s_raw_n);
}

TEST_CASE("stream: a raw run whose sender went silent is aborted, frames resume", "[link][stream]")
{
    uint8_t f1[SAFR_MAX_FRAME], f2[SAFR_MAX_FRAME];
    stream_setup(40); /* first: the codec needs its key to build a frame */
    const size_t n1 = make_frame(f1, 1, 10), n2 = make_frame(f2, 2, 5);
    TEST_ASSERT_TRUE(n1 > 0 && n2 > 0);
    siot_link_stream_feed(&s_st, SIOT_LINK_SERIAL, f1, n1);
    const uint8_t some[10] = {0xA5, 1, 2, 3, 4, 5, 6, 7, 8, 9};
    siot_link_stream_feed(&s_st, SIOT_LINK_SERIAL, some, sizeof(some));
    TEST_ASSERT_EQUAL(10, s_raw_n);
    TEST_ASSERT_EQUAL(0, s_raw_done);
    TEST_ASSERT_EQUAL(30, s_st.raw_left);

    siot_link_stream_abort_raw(&s_st);
    TEST_ASSERT_EQUAL(1, s_raw_aborted);
    TEST_ASSERT_EQUAL(0, s_st.raw_left);
    siot_link_stream_abort_raw(&s_st); /* nothing to abort: no second call */
    TEST_ASSERT_EQUAL(1, s_raw_aborted);

    siot_link_stream_feed(&s_st, SIOT_LINK_SERIAL, f2, n2);
    TEST_ASSERT_EQUAL(2, s_got_n);
    TEST_ASSERT_EQUAL_HEX8_ARRAY(f2, s_got[1], n2);
    TEST_ASSERT_EQUAL(ESP_ERR_INVALID_ARG, siot_link_stream_expect_raw(&s_st, 0, on_raw, NULL));
    TEST_ASSERT_EQUAL(ESP_ERR_INVALID_ARG, siot_link_stream_expect_raw(&s_st, 4, NULL, NULL));
}
