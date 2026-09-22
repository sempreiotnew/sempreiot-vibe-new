/* Dispatcher routing, TX side counters, plaintext policy, stats. */
#include <string.h>

#include "unity.h"

#include "siot_safr.h"
#include "test_support.h"

static int s_hits[256];
static void *s_last_ctx;
static void hit(const siot_safr_frame_t *f, bool duplicate, void *ctx)
{
    (void)duplicate;
    s_hits[f->msg_type]++;
    s_last_ctx = ctx;
}

static size_t from_node(uint8_t *out, uint8_t msg_type, uint16_t msg_id, uint32_t ctr)
{
    uint8_t p[4] = {msg_type, 0, 0, 0};
    return siot_safr_build_frame(out, msg_type, msg_id, TV_SRC_MAC, SAFR_BCAST_MAC, 6, 1, 0, 1, ctr, p, 4);
}

TEST_CASE("dispatch: frames route to the handler registered for their MSG_TYPE", "[safr][dispatch]")
{
    ts_safr_init(TS_OTHER_MAC, 1);
    ts_clock_set(0);
    memset(s_hits, 0, sizeof(s_hits));
    int ctx_a = 1, ctx_b = 2;
    TEST_ASSERT_EQUAL(ESP_OK, siot_safr_register(SAFR_MSG_EVENT, hit, &ctx_a));
    TEST_ASSERT_EQUAL(ESP_OK, siot_safr_register(SAFR_MSG_COMMAND, hit, &ctx_b));

    uint8_t f[SAFR_MAX_FRAME];
    size_t n;
    n = from_node(f, SAFR_MSG_EVENT, 1, 1);
    TEST_ASSERT_EQUAL(SIOT_SAFR_RX_OK, siot_safr_rx(f, n));
    TEST_ASSERT_EQUAL_PTR(&ctx_a, s_last_ctx);
    n = from_node(f, SAFR_MSG_COMMAND, 2, 2);
    TEST_ASSERT_EQUAL(SIOT_SAFR_RX_OK, siot_safr_rx(f, n));
    TEST_ASSERT_EQUAL_PTR(&ctx_b, s_last_ctx);
    n = from_node(f, SAFR_MSG_TOPOLOGY, 3, 3); /* nobody registered */
    TEST_ASSERT_EQUAL(SIOT_SAFR_RX_NO_HANDLER, siot_safr_rx(f, n));

    TEST_ASSERT_EQUAL(1, s_hits[SAFR_MSG_EVENT]);
    TEST_ASSERT_EQUAL(1, s_hits[SAFR_MSG_COMMAND]);
    TEST_ASSERT_EQUAL(0, s_hits[SAFR_MSG_TOPOLOGY]);

    /* Re-registering replaces; unregistering routes to NO_HANDLER. */
    TEST_ASSERT_EQUAL(ESP_OK, siot_safr_register(SAFR_MSG_EVENT, hit, &ctx_b));
    n = from_node(f, SAFR_MSG_EVENT, 4, 4);
    TEST_ASSERT_EQUAL(SIOT_SAFR_RX_OK, siot_safr_rx(f, n));
    TEST_ASSERT_EQUAL_PTR(&ctx_b, s_last_ctx);
    TEST_ASSERT_EQUAL(ESP_OK, siot_safr_unregister(SAFR_MSG_EVENT));
    TEST_ASSERT_EQUAL(ESP_ERR_NOT_FOUND, siot_safr_unregister(SAFR_MSG_EVENT));
    n = from_node(f, SAFR_MSG_EVENT, 5, 5);
    TEST_ASSERT_EQUAL(SIOT_SAFR_RX_NO_HANDLER, siot_safr_rx(f, n));

    siot_safr_stats_t st;
    siot_safr_get_stats(&st);
    TEST_ASSERT_EQUAL(5, st.rx_frames);
    TEST_ASSERT_EQUAL(3, st.rx_ok);
    TEST_ASSERT_EQUAL(2, st.no_handler);
    siot_safr_unregister(SAFR_MSG_COMMAND);
}

TEST_CASE("dispatch: handler table is bounded and a handler may send from inside", "[safr][dispatch]")
{
    ts_safr_init(TS_OTHER_MAC, 1);
    for (int t = 0; t < CONFIG_SIOT_SAFR_HANDLERS_MAX; t++) {
        TEST_ASSERT_EQUAL(ESP_OK, siot_safr_register((uint8_t)(0x40 + t), hit, NULL));
    }
    TEST_ASSERT_EQUAL(ESP_ERR_NO_MEM, siot_safr_register(0x7F, hit, NULL));
    TEST_ASSERT_EQUAL(ESP_ERR_INVALID_ARG, siot_safr_register(0x7F, NULL, NULL));
    for (int t = 0; t < CONFIG_SIOT_SAFR_HANDLERS_MAX; t++) siot_safr_unregister((uint8_t)(0x40 + t));
}

static void ack_back(const siot_safr_frame_t *f, bool duplicate, void *ctx)
{
    (void)duplicate; (void)ctx;
    /* Spec §7.5: ACK {ACKED_MSG_ID, STATUS, 0} — sending from a handler must not deadlock. */
    uint8_t p[4] = {(uint8_t)(f->msg_id >> 8), (uint8_t)f->msg_id, SAFR_ACK_OK, 0};
    TEST_ASSERT_EQUAL(ESP_OK, siot_safr_send(f->src_mac, SAFR_MSG_ACK, siot_safr_next_msg_id(), 0, p, 4));
}

TEST_CASE("dispatch: ACK sent from a handler reaches the TX sink with correct DST", "[safr][dispatch]")
{
    ts_safr_init(TS_OTHER_MAC, 9);
    ts_clock_set(0);
    TEST_ASSERT_EQUAL(ESP_OK, siot_safr_register(SAFR_MSG_COMMAND, ack_back, NULL));
    uint8_t f[SAFR_MAX_FRAME];
    const size_t n = from_node(f, SAFR_MSG_COMMAND, 0x0777, 1);
    TEST_ASSERT_EQUAL(SIOT_SAFR_RX_OK, siot_safr_rx(f, n));
    TEST_ASSERT_EQUAL(1, ts_tx_calls);
    TEST_ASSERT_EQUAL_HEX8_ARRAY(TV_SRC_MAC, ts_tx_dst, 6);

    siot_safr_frame_t ack;
    TEST_ASSERT_EQUAL(SIOT_SAFR_PARSE_OK, siot_safr_parse_frame(ts_tx_frame, ts_tx_len, &ack));
    TEST_ASSERT_EQUAL_HEX8(SAFR_MSG_ACK, ack.msg_type);
    TEST_ASSERT_EQUAL_HEX8_ARRAY(TS_OTHER_MAC, ack.src_mac, 6);
    TEST_ASSERT_EQUAL_HEX8_ARRAY(TV_SRC_MAC, ack.dst_mac, 6);
    TEST_ASSERT_EQUAL_HEX16(9, ack.boot_ctr);
    TEST_ASSERT_EQUAL_HEX8(0x07, ack.payload[0]);
    TEST_ASSERT_EQUAL_HEX8(0x77, ack.payload[1]);
    siot_safr_unregister(SAFR_MSG_COMMAND);
}

TEST_CASE("send: fresh MSG_CTR per frame, TTL/HOPS from level, errors", "[safr][tx]")
{
    ts_safr_init(TS_OTHER_MAC, 2);
    uint8_t p[4] = {1, 2, 3, 4};
    siot_safr_frame_t rx;

    siot_safr_set_level(2);
    const uint16_t id = siot_safr_next_msg_id();
    TEST_ASSERT_EQUAL(ESP_OK, siot_safr_send(SAFR_CENTRAL_MAC, SAFR_MSG_ACK, id, SAFR_F_ACK_REQ, p, 4));
    TEST_ASSERT_EQUAL(SIOT_SAFR_PARSE_OK, siot_safr_parse_frame(ts_tx_frame, ts_tx_len, &rx));
    TEST_ASSERT_EQUAL_HEX8(5, rx.ttl);
    TEST_ASSERT_EQUAL_HEX8(2, rx.hops);
    TEST_ASSERT_EQUAL_HEX8(SAFR_F_ACK_REQ | SAFR_F_ENC, rx.flags);
    TEST_ASSERT_EQUAL_HEX32(1, rx.msg_ctr);
    TEST_ASSERT_EQUAL_HEX16(id, rx.msg_id);
    TEST_ASSERT_EQUAL_HEX8_ARRAY(TS_OTHER_MAC, rx.src_mac, 6);
    TEST_ASSERT_EQUAL_HEX8_ARRAY(SAFR_CENTRAL_MAC, rx.dst_mac, 6);

    /* Fast retry: same MSG_ID, MSG_CTR must move on. */
    TEST_ASSERT_EQUAL(ESP_OK, siot_safr_send(SAFR_CENTRAL_MAC, SAFR_MSG_ACK, id, SAFR_F_ACK_REQ, p, 4));
    TEST_ASSERT_EQUAL(SIOT_SAFR_PARSE_OK, siot_safr_parse_frame(ts_tx_frame, ts_tx_len, &rx));
    TEST_ASSERT_EQUAL_HEX32(2, rx.msg_ctr);
    TEST_ASSERT_EQUAL_HEX16(id, rx.msg_id);
    TEST_ASSERT_EQUAL_HEX16(id + 1, siot_safr_next_msg_id());

    uint8_t big[SAFR_MAX_PAYLOAD + 1] = {0};
    TEST_ASSERT_EQUAL(ESP_ERR_INVALID_SIZE, siot_safr_send(SAFR_BCAST_MAC, SAFR_MSG_EVENT, 1, 0, big, sizeof(big)));
    siot_safr_set_tx(NULL, NULL);
    TEST_ASSERT_EQUAL(ESP_ERR_INVALID_STATE, siot_safr_send(SAFR_BCAST_MAC, SAFR_MSG_EVENT, 1, 0, p, 4));

    siot_safr_stats_t st;
    siot_safr_get_stats(&st);
    TEST_ASSERT_EQUAL(2, st.tx_frames);
    TEST_ASSERT_EQUAL(0, st.tx_failed);
}

TEST_CASE("rx: plaintext frames are rejected unless allow_plaintext", "[safr][rx]")
{
    ts_safr_init(TS_OTHER_MAC, 1);
    memset(s_hits, 0, sizeof(s_hits));
    TEST_ASSERT_EQUAL(ESP_OK, siot_safr_register(SAFR_MSG_COMMAND, hit, NULL));

    /* Hand-build an F_ENC = 0 frame: header + 4 B payload + CRC (no tag). */
    uint8_t f[SAFR_HDR_LEN + 4 + SAFR_CRC_LEN];
    memset(f, 0, sizeof(f));
    f[0] = SAFR_SOF; f[1] = SAFR_VER; f[2] = 0; f[3] = sizeof(f);
    f[4] = SAFR_MSG_COMMAND; f[5] = 0; f[6] = 1; f[7] = TV_SYSTEM_ID >> 8; f[8] = TV_SYSTEM_ID & 0xFF;
    memcpy(&f[9], TV_SRC_MAC, 6); memcpy(&f[15], SAFR_BCAST_MAC, 6);
    f[21] = 7; f[22] = 0; f[23] = 0; f[24] = 0; f[25] = 1; f[29] = 1;
    f[30] = SAFR_CMD_LINK_CHECK; f[31] = 0;
    const uint16_t crc = siot_safr_crc16(f, sizeof(f) - SAFR_CRC_LEN);
    f[sizeof(f) - 2] = (uint8_t)(crc >> 8); f[sizeof(f) - 1] = (uint8_t)crc;

    TEST_ASSERT_EQUAL(SIOT_SAFR_RX_PLAINTEXT_REJECTED, siot_safr_rx(f, sizeof(f)));
    TEST_ASSERT_EQUAL(0, s_hits[SAFR_MSG_COMMAND]);
    siot_safr_stats_t st;
    siot_safr_get_stats(&st);
    TEST_ASSERT_EQUAL(1, st.plaintext_rejected);

    /* Bench mode accepts it and the payload arrives verbatim. */
    siot_safr_config_t cfg = {.system_id = TV_SYSTEM_ID, .boot_ctr = 1, .now_ms = ts_clock_now,
                              .allow_plaintext = true};
    memcpy(cfg.safr_psk, TV_PSK, 16);
    memcpy(cfg.src_mac, TS_OTHER_MAC, 6);
    TEST_ASSERT_EQUAL(ESP_OK, siot_safr_init(&cfg));
    TEST_ASSERT_EQUAL(SIOT_SAFR_RX_OK, siot_safr_rx(f, sizeof(f)));
    TEST_ASSERT_EQUAL(1, s_hits[SAFR_MSG_COMMAND]);
    siot_safr_unregister(SAFR_MSG_COMMAND);
}

TEST_CASE("rx: stats count bad frame / foreign / auth and reset", "[safr][rx]")
{
    ts_safr_init(TS_OTHER_MAC, 1);
    uint8_t f[SAFR_MAX_FRAME], g[SAFR_MAX_FRAME];
    const size_t n = from_node(f, SAFR_MSG_EVENT, 1, 1);

    memcpy(g, f, n); g[n - 1] ^= 1;
    TEST_ASSERT_EQUAL(SIOT_SAFR_RX_BAD_FRAME, siot_safr_rx(g, n));

    memcpy(g, f, n); g[8] ^= 1;
    uint16_t crc = siot_safr_crc16(g, n - 2); g[n - 2] = crc >> 8; g[n - 1] = (uint8_t)crc;
    TEST_ASSERT_EQUAL(SIOT_SAFR_RX_FOREIGN, siot_safr_rx(g, n));

    memcpy(g, f, n); g[n - 3] ^= 1; /* last tag byte */
    crc = siot_safr_crc16(g, n - 2); g[n - 2] = crc >> 8; g[n - 1] = (uint8_t)crc;
    TEST_ASSERT_EQUAL(SIOT_SAFR_RX_AUTH_FAILED, siot_safr_rx(g, n));

    siot_safr_stats_t st;
    siot_safr_get_stats(&st);
    TEST_ASSERT_EQUAL(3, st.rx_frames);
    TEST_ASSERT_EQUAL(1, st.bad_frame);
    TEST_ASSERT_EQUAL(1, st.foreign);
    TEST_ASSERT_EQUAL(1, st.auth);
    siot_safr_reset_stats();
    siot_safr_get_stats(&st);
    TEST_ASSERT_EQUAL(0, st.rx_frames + st.bad_frame + st.foreign + st.auth);
}
