/* Appendix A of docs/safr/protocol-safr-v3.md: V1–V3 byte-exact, both
 * directions. Built through siot_safr_send() so the device-side counters
 * (MSG_ID 1..3, MSG_CTR 1..3, BOOT_CTR 1, TTL 7 / HOPS 0) are exercised too. */
#include <string.h>

#include "unity.h"

#include "siot_safr.h"
#include "test_support.h"

typedef struct {
    const char *name;
    uint8_t     msg_type;
    const char *payload_hex;
    const char *frame_hex;
    size_t      frame_len;
} vector_t;

static const vector_t VECTORS[3] = {
    {"V1 EVENT", SAFR_MSG_EVENT,
     "0301686E2F000555106802262A00000001",
     "A503004101000153465A4652000001FFFFFFFFFFFF07000100010000000141AF9429BA4D87A82CC6B4BE0C598D6A9244EE915438245C31277D89868FA4723F5820",
     65},
    {"V2 HEARTBEAT", SAFR_MSG_HEARTBEAT,
     "686E2F0100000E10016400FA7F00000000000100",
     "A503004402000253465A4652000001FFFFFFFFFFFF07000100010000000212D0A08D33693CEA467B1F3810E79100A6AEEB92C38A0DFC61192C6FD3A987FA85DFF5C9E9ED",
     68},
    {"V3 TOPOLOGY", SAFR_MSG_TOPOLOGY,
     "686E2F0200000000000000017F025A4652000002BE5A4652000003C4",
     "A503004C03000353465A4652000001FFFFFFFFFFFF070001000100000003D92DFFDAFE51A2120096E2C02AA08E7655180495E70530D730B37389B0278118BAD4AE559B6C5FDE8530F8D233A1",
     76},
};

TEST_CASE("vectors: build V1–V3 byte-exact via siot_safr_send()", "[safr][vectors]")
{
    ts_safr_init(TV_SRC_MAC, TV_BOOT_CTR);
    for (int i = 0; i < 3; i++) {
        const vector_t *v = &VECTORS[i];
        uint8_t payload[64], expect[128];
        const size_t plen = ts_unhex(v->payload_hex, payload, sizeof(payload));
        const size_t flen = ts_unhex(v->frame_hex, expect, sizeof(expect));
        TEST_ASSERT_EQUAL_MESSAGE(v->frame_len, flen, v->name);

        const uint16_t msg_id = siot_safr_next_msg_id();
        TEST_ASSERT_EQUAL_MESSAGE(i + 1, msg_id, v->name);
        TEST_ASSERT_EQUAL_MESSAGE(ESP_OK, siot_safr_send(SAFR_BCAST_MAC, v->msg_type, msg_id, 0,
                                                         payload, plen), v->name);
        TEST_ASSERT_EQUAL_MESSAGE(flen, ts_tx_len, v->name);
        TEST_ASSERT_EQUAL_HEX8_ARRAY_MESSAGE(expect, ts_tx_frame, flen, v->name);
        TEST_ASSERT_EQUAL_HEX8_ARRAY(SAFR_BCAST_MAC, ts_tx_dst, 6);
    }
    TEST_ASSERT_EQUAL(3, ts_tx_calls);
}

TEST_CASE("vectors: build V1 byte-exact via siot_safr_build_frame()", "[safr][vectors]")
{
    ts_safr_init(TS_OTHER_MAC, 5); /* our own identity is irrelevant to the codec call */
    uint8_t payload[64], expect[128], frame[SAFR_MAX_FRAME];
    const size_t plen = ts_unhex(VECTORS[0].payload_hex, payload, sizeof(payload));
    const size_t flen = ts_unhex(VECTORS[0].frame_hex, expect, sizeof(expect));
    const size_t n = siot_safr_build_frame(frame, SAFR_MSG_EVENT, 0x0001, TV_SRC_MAC, SAFR_BCAST_MAC,
                                           7, 0, SAFR_F_ENC, 0x0001, 0x00000001u, payload, plen);
    TEST_ASSERT_EQUAL(flen, n);
    TEST_ASSERT_EQUAL_HEX8_ARRAY(expect, frame, flen);
}

static uint8_t s_got_payload[SAFR_MAX_PAYLOAD];
static size_t  s_got_len;
static int     s_got_calls;
static bool    s_got_dup;

static void capture(const siot_safr_frame_t *f, const uint8_t *raw, size_t raw_len,
                    bool duplicate, void *ctx)
{
    (void)ctx;
    TEST_ASSERT_EQUAL_HEX8(SAFR_SOF, raw[0]);
    TEST_ASSERT_EQUAL(raw_len, ((size_t)raw[2] << 8) | raw[3]);
    memcpy(s_got_payload, f->payload, f->payload_len);
    s_got_len = f->payload_len;
    s_got_dup = duplicate;
    s_got_calls++;
}

TEST_CASE("vectors: parse V1–V3 through the RX pipeline (codec + counters)", "[safr][vectors]")
{
    ts_safr_init(TS_OTHER_MAC, 1);
    ts_clock_set(1000);
    for (int i = 0; i < 3; i++) {
        TEST_ASSERT_EQUAL(ESP_OK, siot_safr_register(VECTORS[i].msg_type, capture, NULL));
    }
    for (int i = 0; i < 3; i++) {
        const vector_t *v = &VECTORS[i];
        uint8_t payload[64], frame[128];
        const size_t plen = ts_unhex(v->payload_hex, payload, sizeof(payload));
        const size_t flen = ts_unhex(v->frame_hex, frame, sizeof(frame));

        /* Codec alone */
        siot_safr_frame_t rx;
        TEST_ASSERT_EQUAL_MESSAGE(SIOT_SAFR_PARSE_OK, siot_safr_parse_frame(frame, flen, &rx), v->name);
        TEST_ASSERT_EQUAL_MESSAGE(v->msg_type, rx.msg_type, v->name);
        TEST_ASSERT_EQUAL_MESSAGE(i + 1, rx.msg_id, v->name);
        TEST_ASSERT_EQUAL_MESSAGE(i + 1, rx.msg_ctr, v->name);
        TEST_ASSERT_EQUAL_MESSAGE(TV_BOOT_CTR, rx.boot_ctr, v->name);
        TEST_ASSERT_EQUAL_HEX8_ARRAY_MESSAGE(TV_SRC_MAC, rx.src_mac, 6, v->name);
        TEST_ASSERT_EQUAL_MESSAGE(plen, rx.payload_len, v->name);
        TEST_ASSERT_EQUAL_HEX8_ARRAY_MESSAGE(payload, rx.payload, plen, v->name);

        /* Full pipeline: replay + dedupe + dispatcher */
        s_got_calls = 0;
        TEST_ASSERT_EQUAL_MESSAGE(SIOT_SAFR_RX_OK, siot_safr_rx(frame, flen), v->name);
        TEST_ASSERT_EQUAL(1, s_got_calls);
        TEST_ASSERT_FALSE(s_got_dup);
        TEST_ASSERT_EQUAL(plen, s_got_len);
        TEST_ASSERT_EQUAL_HEX8_ARRAY(payload, s_got_payload, plen);
    }
    for (int i = 0; i < 3; i++) siot_safr_unregister(VECTORS[i].msg_type);

    siot_safr_stats_t st;
    siot_safr_get_stats(&st);
    TEST_ASSERT_EQUAL(3, st.rx_frames);
    TEST_ASSERT_EQUAL(3, st.rx_ok);
    TEST_ASSERT_EQUAL(0, st.replay + st.dup + st.auth + st.foreign + st.bad_frame);
}
