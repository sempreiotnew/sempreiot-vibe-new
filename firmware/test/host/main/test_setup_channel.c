/* SAFR v3.2 setup channel (spec §3.1, Appendix A V-SETINST) against the
 * app's fixture mobile/sempreiot_central_app/test/fixtures/setinst_vectors.json:
 * the tablet derives the key from the board sticker (id + pop) and sends
 * SET_INSTALLATION under SYSTEM_ID 0x0000; the board must reproduce the
 * key, parse the frame with siot_safr_parse_frame_with() and rebuild it
 * byte for byte with siot_safr_build_frame_with(). */
#include <string.h>

#include "unity.h"

#include "siot_provisioning.h"
#include "siot_safr.h"
#include "test_support.h"

static const char ID[]  = "dev-00000001";
static const char POP[] = "0123456789ABCDEF";
static const char KEY_HEX[] = "51C8D95986F21556529FF9486852FD0F";
static const char PAYLOAD_HEX[] =
    "1138123406340953494F542D31323334105152326865737A5772306D4A6A6144"
    "6400112233445566778899AABBCCDDEEFF0847616C70616F2032";
static const char FRAME_HEX[] =
    "A503006A05000100000000000000017C4FADAE8590070003000100000001C225FCF43E43827B4FD5EDDA0B41299F"
    "4C178AE6782268B6FFAD50881B8444211BF8857E986A6260702EAB5C3586FB1BC361003D3F54E0E06BEB2AD02B57"
    "B2AEE6269FF8A8187285E2DD660D";

TEST_CASE("setup: HKDF setup key matches the app fixture", "[prov][setup]")
{
    uint8_t key[16], expect[16];
    ts_unhex(KEY_HEX, expect, sizeof(expect));
    siot_prov_derive_setup_key(ID, POP, key);
    TEST_ASSERT_EQUAL_HEX8_ARRAY(expect, key, 16);
}

TEST_CASE("setup: V-SETINST parses under SYSTEM_ID 0 + setup key, and rebuilds byte-exact", "[safr][setup]")
{
    uint8_t key[16], frame[SAFR_MAX_FRAME], payload[128], out[SAFR_MAX_FRAME];
    siot_prov_derive_setup_key(ID, POP, key);
    const size_t flen = ts_unhex(FRAME_HEX, frame, sizeof(frame));
    const size_t plen = ts_unhex(PAYLOAD_HEX, payload, sizeof(payload));

    /* The installed identity is the bench one: on it the frame is foreign. */
    ts_safr_init(TS_OTHER_MAC, 5);
    siot_safr_frame_t rx;
    TEST_ASSERT_EQUAL(SIOT_SAFR_PARSE_FOREIGN, siot_safr_parse_frame(frame, flen, &rx));

    TEST_ASSERT_EQUAL(SIOT_SAFR_PARSE_OK, siot_safr_parse_frame_with(0x0000, key, frame, flen, &rx));
    TEST_ASSERT_EQUAL(SAFR_MSG_COMMAND, rx.msg_type);
    TEST_ASSERT_EQUAL(0x0000, rx.system_id);
    TEST_ASSERT_EQUAL(plen, rx.payload_len);
    TEST_ASSERT_EQUAL_HEX8_ARRAY(payload, rx.payload, plen);
    TEST_ASSERT_EQUAL(SAFR_CMD_SET_INSTALLATION, rx.payload[0]);
    TEST_ASSERT_EQUAL(0x12, rx.payload[2]); /* system_id 0x1234 */
    TEST_ASSERT_EQUAL(0x34, rx.payload[3]);

    /* Wrong pop → wrong key → auth failure, never a parse of the code. */
    uint8_t wrong[16];
    siot_prov_derive_setup_key(ID, "0123456789ABCDEG", wrong);
    TEST_ASSERT_EQUAL(SIOT_SAFR_PARSE_AUTH_FAILED, siot_safr_parse_frame_with(0x0000, wrong, frame, flen, &rx));

    const uint8_t central[6] = {0, 0, 0, 0, 0, 1};
    const uint8_t board[6] = {0x7C, 0x4F, 0xAD, 0xAE, 0x85, 0x90};
    const size_t n = siot_safr_build_frame_with(0x0000, key, out, SAFR_MSG_COMMAND, 1, central, board,
                                                7, 0, SAFR_F_ACK_REQ, 1, 1, payload, plen);
    TEST_ASSERT_EQUAL(flen, n);
    TEST_ASSERT_EQUAL_HEX8_ARRAY(frame, out, flen);
}
