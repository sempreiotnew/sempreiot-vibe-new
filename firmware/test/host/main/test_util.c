#include <string.h>

#include "unity.h"

#include "siot_util.h"

TEST_CASE("util: put/get u16/u32 are big-endian", "[util]")
{
    uint8_t b[4];
    siot_put_u16(b, 0x1234);
    TEST_ASSERT_EQUAL_HEX8(0x12, b[0]);
    TEST_ASSERT_EQUAL_HEX8(0x34, b[1]);
    TEST_ASSERT_EQUAL_HEX16(0x1234, siot_get_u16(b));

    siot_put_u32(b, 0x686E2F00u);
    const uint8_t exp[4] = {0x68, 0x6E, 0x2F, 0x00};
    TEST_ASSERT_EQUAL_HEX8_ARRAY(exp, b, 4);
    TEST_ASSERT_EQUAL_HEX32(0x686E2F00u, siot_get_u32(b));

    siot_put_u16(b, (uint16_t)0x7FFF);
    TEST_ASSERT_EQUAL_HEX16(0x7FFF, siot_get_u16(b));
}

TEST_CASE("util: hex encode/decode", "[util]")
{
    const uint8_t in[4] = {0x25, 0x11, 0x8B, 0xA1};
    char out[9];
    TEST_ASSERT_EQUAL(8, siot_hex_encode(in, 4, out, sizeof(out)));
    TEST_ASSERT_EQUAL_STRING("25118ba1", out);

    char small[8];
    TEST_ASSERT_EQUAL(0, siot_hex_encode(in, 4, small, sizeof(small)));
    TEST_ASSERT_EQUAL_CHAR('\0', small[0]);

    uint8_t dec[4];
    TEST_ASSERT_EQUAL(4, siot_hex_decode("25118BA1", dec, sizeof(dec)));
    TEST_ASSERT_EQUAL_HEX8_ARRAY(in, dec, 4);
    TEST_ASSERT_EQUAL(4, siot_hex_decode("25118ba1", dec, sizeof(dec)));
    TEST_ASSERT_EQUAL(-1, siot_hex_decode("251", dec, sizeof(dec)));     /* odd */
    TEST_ASSERT_EQUAL(-1, siot_hex_decode("25zz", dec, sizeof(dec)));    /* bad char */
    TEST_ASSERT_EQUAL(-1, siot_hex_decode("2511223344", dec, sizeof(dec))); /* too long */
}

TEST_CASE("util: mac to/from string, eq, bcast", "[util]")
{
    const uint8_t mac[6] = {0x5A, 0x46, 0x52, 0x00, 0x00, 0x01};
    char s[SIOT_MAC_STR_LEN];
    TEST_ASSERT_EQUAL_STRING("5A:46:52:00:00:01", siot_mac_to_str(mac, s));

    uint8_t parsed[6];
    TEST_ASSERT_TRUE(siot_mac_from_str("5a:46:52:00:00:01", parsed));
    TEST_ASSERT_EQUAL_HEX8_ARRAY(mac, parsed, 6);
    TEST_ASSERT_TRUE(siot_mac_from_str("5A-46-52-00-00-01", parsed));
    TEST_ASSERT_EQUAL_HEX8_ARRAY(mac, parsed, 6);
    TEST_ASSERT_TRUE(siot_mac_from_str("5A4652000001", parsed));
    TEST_ASSERT_EQUAL_HEX8_ARRAY(mac, parsed, 6);
    TEST_ASSERT_FALSE(siot_mac_from_str("5A:46:52:00:00", parsed));
    TEST_ASSERT_FALSE(siot_mac_from_str("5A:46:52:00:00:01:02", parsed));
    TEST_ASSERT_FALSE(siot_mac_from_str("5A:46:52:00:00:0G", parsed));

    const uint8_t bc[6] = {0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF};
    TEST_ASSERT_TRUE(siot_mac_is_bcast(bc));
    TEST_ASSERT_FALSE(siot_mac_is_bcast(mac));
    TEST_ASSERT_TRUE(siot_mac_eq(mac, parsed));
    TEST_ASSERT_FALSE(siot_mac_eq(mac, bc));
}
