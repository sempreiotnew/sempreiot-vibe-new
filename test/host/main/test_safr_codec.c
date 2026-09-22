/* Codec-level tests: CRC check value, build/parse round-trip, LEN <= 250,
 * the three parse failure classes of spec §3.3 / §10. */
#include <string.h>

#include "unity.h"

#include "siot_safr.h"
#include "test_support.h"

TEST_CASE("safr: CRC-16/CCITT-FALSE check value is 0x29B1", "[safr][crc]")
{
    TEST_ASSERT_EQUAL_HEX16(0x29B1, siot_safr_crc16((const uint8_t *)"123456789", 9));
    TEST_ASSERT_EQUAL_HEX16(0xFFFF, siot_safr_crc16((const uint8_t *)"", 0));
}

TEST_CASE("safr: build/parse round-trip keeps header and payload", "[safr][codec]")
{
    ts_safr_init(TS_OTHER_MAC, 7);

    uint8_t payload[SAFR_EVENT_LEN];
    for (int i = 0; i < SAFR_EVENT_LEN; i++) payload[i] = (uint8_t)(0xA0 + i);

    uint8_t frame[SAFR_MAX_FRAME];
    const size_t n = siot_safr_build_frame(frame, SAFR_MSG_EVENT, 0x1234, TV_SRC_MAC,
                                           SAFR_BCAST_MAC, 5, 2, SAFR_F_ACK_REQ,
                                           0x0102, 0x03040506u, payload, sizeof(payload));
    TEST_ASSERT_EQUAL(SAFR_HDR_LEN + SAFR_EVENT_LEN + SAFR_TAG_LEN + SAFR_CRC_LEN, n);
    TEST_ASSERT_EQUAL_HEX8(SAFR_SOF, frame[0]);
    TEST_ASSERT_EQUAL_HEX8(SAFR_VER, frame[1]);
    TEST_ASSERT_EQUAL_HEX8(SAFR_F_ACK_REQ | SAFR_F_ENC, frame[23]); /* F_ENC forced on */
    TEST_ASSERT_TRUE(memcmp(&frame[SAFR_HDR_LEN], payload, SAFR_EVENT_LEN) != 0); /* encrypted */

    siot_safr_frame_t rx;
    TEST_ASSERT_EQUAL(SIOT_SAFR_PARSE_OK, siot_safr_parse_frame(frame, n, &rx));
    TEST_ASSERT_EQUAL_HEX8(SAFR_MSG_EVENT, rx.msg_type);
    TEST_ASSERT_EQUAL_HEX16(0x1234, rx.msg_id);
    TEST_ASSERT_EQUAL_HEX16(TV_SYSTEM_ID, rx.system_id);
    TEST_ASSERT_EQUAL_HEX8_ARRAY(TV_SRC_MAC, rx.src_mac, 6);
    TEST_ASSERT_EQUAL_HEX8_ARRAY(SAFR_BCAST_MAC, rx.dst_mac, 6);
    TEST_ASSERT_EQUAL_HEX8(5, rx.ttl);
    TEST_ASSERT_EQUAL_HEX8(2, rx.hops);
    TEST_ASSERT_EQUAL_HEX8(SAFR_F_ACK_REQ | SAFR_F_ENC, rx.flags);
    TEST_ASSERT_EQUAL_HEX16(0x0102, rx.boot_ctr);
    TEST_ASSERT_EQUAL_HEX32(0x03040506u, rx.msg_ctr);
    TEST_ASSERT_EQUAL(SAFR_EVENT_LEN, rx.payload_len);
    TEST_ASSERT_EQUAL_HEX8_ARRAY(payload, rx.payload, SAFR_EVENT_LEN);
}

TEST_CASE("safr: empty payload and max payload (202) round-trip, 203 rejected", "[safr][codec]")
{
    ts_safr_init(TS_OTHER_MAC, 1);
    uint8_t frame[SAFR_MAX_FRAME + 16];
    siot_safr_frame_t rx;

    size_t n = siot_safr_build_frame(frame, SAFR_MSG_COMMAND, 1, TV_SRC_MAC, SAFR_BCAST_MAC,
                                     7, 0, 0, 1, 1, NULL, 0);
    TEST_ASSERT_EQUAL(SAFR_HDR_LEN + SAFR_TAG_LEN + SAFR_CRC_LEN, n); /* 30 + 16 + 2 = 48 */
    TEST_ASSERT_EQUAL(SIOT_SAFR_PARSE_OK, siot_safr_parse_frame(frame, n, &rx));
    TEST_ASSERT_EQUAL(0, rx.payload_len);

    uint8_t big[SAFR_MAX_PAYLOAD + 1];
    memset(big, 0x5A, sizeof(big));
    n = siot_safr_build_frame(frame, SAFR_MSG_INSTALLATION, 2, TV_SRC_MAC, SAFR_BCAST_MAC,
                              7, 0, 0, 1, 2, big, SAFR_MAX_PAYLOAD);
    TEST_ASSERT_EQUAL(SAFR_MAX_FRAME, n);
    TEST_ASSERT_EQUAL(SIOT_SAFR_PARSE_OK, siot_safr_parse_frame(frame, n, &rx));
    TEST_ASSERT_EQUAL(SAFR_MAX_PAYLOAD, rx.payload_len);

    n = siot_safr_build_frame(frame, SAFR_MSG_INSTALLATION, 3, TV_SRC_MAC, SAFR_BCAST_MAC,
                              7, 0, 0, 1, 3, big, SAFR_MAX_PAYLOAD + 1);
    TEST_ASSERT_EQUAL(0, n);
}

TEST_CASE("safr: parse rejects bad SOF/VER/LEN/CRC as BAD_FRAME", "[safr][codec]")
{
    ts_safr_init(TS_OTHER_MAC, 1);
    uint8_t frame[SAFR_MAX_FRAME];
    uint8_t p[4] = {1, 2, 3, 4};
    const size_t n = siot_safr_build_frame(frame, SAFR_MSG_ACK, 9, TV_SRC_MAC, SAFR_BCAST_MAC,
                                           7, 0, 0, 1, 9, p, 4);
    TEST_ASSERT_TRUE(n > 0);
    siot_safr_frame_t rx;
    uint8_t bad[SAFR_MAX_FRAME];

    memcpy(bad, frame, n); bad[0] = 0x5A;
    TEST_ASSERT_EQUAL(SIOT_SAFR_PARSE_BAD_FRAME, siot_safr_parse_frame(bad, n, &rx));

    memcpy(bad, frame, n); bad[1] = 0x02;
    TEST_ASSERT_EQUAL(SIOT_SAFR_PARSE_BAD_FRAME, siot_safr_parse_frame(bad, n, &rx));

    memcpy(bad, frame, n); bad[3] += 1; /* LEN != len */
    TEST_ASSERT_EQUAL(SIOT_SAFR_PARSE_BAD_FRAME, siot_safr_parse_frame(bad, n, &rx));

    memcpy(bad, frame, n); bad[n - 1] ^= 0x01; /* CRC */
    TEST_ASSERT_EQUAL(SIOT_SAFR_PARSE_BAD_FRAME, siot_safr_parse_frame(bad, n, &rx));

    memcpy(bad, frame, n); bad[SAFR_HDR_LEN] ^= 0x01; /* ciphertext bit flip -> CRC catches it */
    TEST_ASSERT_EQUAL(SIOT_SAFR_PARSE_BAD_FRAME, siot_safr_parse_frame(bad, n, &rx));

    TEST_ASSERT_EQUAL(SIOT_SAFR_PARSE_BAD_FRAME, siot_safr_parse_frame(frame, SAFR_MIN_FRAME - 1, &rx));

    /* LEN > 250: a 256-byte POC-era frame is refused before any decryption */
    memset(bad, 0, sizeof(bad));
    bad[0] = SAFR_SOF; bad[1] = SAFR_VER; bad[2] = 0x01; bad[3] = 0x00;
    TEST_ASSERT_EQUAL(SIOT_SAFR_PARSE_BAD_FRAME, siot_safr_parse_frame(bad, 250, &rx));
}

TEST_CASE("safr: foreign SYSTEM_ID dropped before decrypt; wrong key fails auth", "[safr][codec]")
{
    ts_safr_init(TS_OTHER_MAC, 1);
    uint8_t frame[SAFR_MAX_FRAME];
    uint8_t p[4] = {1, 2, 3, 4};
    const size_t n = siot_safr_build_frame(frame, SAFR_MSG_ACK, 9, TV_SRC_MAC, SAFR_BCAST_MAC,
                                           7, 0, 0, 1, 9, p, 4);
    siot_safr_frame_t rx;

    /* Same frame with the header's SYSTEM_ID patched and the CRC recomputed:
     * a neighbouring installation. Never decrypted, so the (now wrong) tag
     * is not what rejects it. */
    uint8_t foreign[SAFR_MAX_FRAME];
    memcpy(foreign, frame, n);
    foreign[7] = 0x11; foreign[8] = 0x22;
    const uint16_t crc = siot_safr_crc16(foreign, n - SAFR_CRC_LEN);
    foreign[n - 2] = (uint8_t)(crc >> 8); foreign[n - 1] = (uint8_t)crc;
    TEST_ASSERT_EQUAL(SIOT_SAFR_PARSE_FOREIGN, siot_safr_parse_frame(foreign, n, &rx));

    /* Same installation id, wrong PSK on the receiver: CCM tag mismatch. */
    siot_safr_config_t cfg = {.system_id = TV_SYSTEM_ID, .boot_ctr = 1, .now_ms = ts_clock_now};
    memcpy(cfg.safr_psk, TV_PSK, 16);
    cfg.safr_psk[15] ^= 0xFF;
    memcpy(cfg.src_mac, TS_OTHER_MAC, 6);
    TEST_ASSERT_EQUAL(ESP_OK, siot_safr_init(&cfg));
    TEST_ASSERT_EQUAL(SIOT_SAFR_PARSE_AUTH_FAILED, siot_safr_parse_frame(frame, n, &rx));

    /* A header bit flip with a fixed-up CRC also fails the tag (AAD). */
    ts_safr_init(TS_OTHER_MAC, 1);
    memcpy(foreign, frame, n);
    foreign[21] = 3; /* TTL */
    const uint16_t crc2 = siot_safr_crc16(foreign, n - SAFR_CRC_LEN);
    foreign[n - 2] = (uint8_t)(crc2 >> 8); foreign[n - 1] = (uint8_t)crc2;
    TEST_ASSERT_EQUAL(SIOT_SAFR_PARSE_AUTH_FAILED, siot_safr_parse_frame(foreign, n, &rx));
}
