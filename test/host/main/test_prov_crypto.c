/* Provisioning crypto against the app's vectors
 * (mobile/sempreiot_central_app/test/provisioning/provisioning_crypto_vectors_test.dart,
 * themselves pinned against an independent Python implementation):
 *   pop = "abc123POP0000", id = "dev-001", nonce = 00..0f, nonce2 = 100..111. */
#include <string.h>

#include "unity.h"

#include "mbedtls/base64.h"
#include "siot_provisioning.h"

static const char POP[] = "abc123POP0000";
static const char ID[]  = "dev-001";

/* base64(nonce2 ‖ ciphertext ‖ tag) exactly as the Dart test asserts it. */
static const char ENVELOPE_B64[] =
    "ZGVmZ2hpamtsbW5vZA6SMAVjBCA5knF0hb/mDDICrihN0fQs3Qb7mzLMGNLTlSy6"
    "TlhPpZv4gHcT1snedBiE+3StIAXuSyi+bRL/NZgmOtg7AOFntfpbNKMZfMHbhsf8"
    "4xkKhmkoEpUi16k3YOhcxd4jEVpL75qgbb8RLnkNs2jCPWsjmFLbx/EMxL001UgA"
    "zn97o6i/FXSKuU7I9hhCAvUVhtsV2zR/BUVQLQ==";

/* jsonEncode(codeJson) in Dart: keys in insertion order, no spaces. */
static const char CODE_JSON[] =
    "{\"system_id\":4660,\"net_ssid\":\"SIOT-TEST\",\"net_psk\":\"testpassword1234\","
    "\"safr_psk_hex\":\"00000000000000000000000000000000\",\"channel\":6,\"mesh_id\":1}";

static void nonce16(uint8_t out[16]) { for (int i = 0; i < 16; i++) out[i] = (uint8_t)i; }

TEST_CASE("prov: HMAC-SHA256 proof matches the app vector", "[prov]")
{
    uint8_t nonce[16];
    nonce16(nonce);
    char proof[65];
    siot_prov_proof(POP, nonce, sizeof(nonce), proof);
    TEST_ASSERT_EQUAL_STRING("e8f237ab91926a890eb12815d34f8edc10de0920bb1be5d74a50df462a034a6f", proof);
}

TEST_CASE("prov: HKDF-SHA256 key matches the app vector", "[prov]")
{
    uint8_t nonce[16], key[16];
    nonce16(nonce);
    siot_prov_derive_key(POP, nonce, sizeof(nonce), key);
    const uint8_t expect[16] = {0xb8, 0x51, 0xff, 0x6f, 0x8b, 0x7c, 0x6b, 0x64,
                                0xec, 0x35, 0x70, 0xe1, 0x53, 0x28, 0x3d, 0xf2};
    TEST_ASSERT_EQUAL_HEX8_ARRAY(expect, key, 16);
}

TEST_CASE("prov: AES-128-CCM envelope from the app decrypts to code_json", "[prov]")
{
    uint8_t nonce[16], key[16];
    nonce16(nonce);
    siot_prov_derive_key(POP, nonce, sizeof(nonce), key);

    uint8_t raw[256];
    size_t raw_len = 0;
    TEST_ASSERT_EQUAL(0, mbedtls_base64_decode(raw, sizeof(raw), &raw_len,
                                               (const uint8_t *)ENVELOPE_B64, strlen(ENVELOPE_B64)));
    /* nonce2 = 100..111 travels in clear at the front */
    for (int i = 0; i < 12; i++) TEST_ASSERT_EQUAL_HEX8(100 + i, raw[i]);

    uint8_t plain[256];
    size_t plain_len = 0;
    TEST_ASSERT_EQUAL(0, siot_prov_decrypt_envelope(key, raw, raw_len, ID, plain, sizeof(plain) - 1,
                                                    &plain_len));
    plain[plain_len] = '\0';
    TEST_ASSERT_EQUAL_STRING(CODE_JSON, (const char *)plain);

    /* Wrong aad (another unit's id), wrong key, damaged tag: all rejected. */
    TEST_ASSERT_NOT_EQUAL(0, siot_prov_decrypt_envelope(key, raw, raw_len, "dev-002", plain,
                                                        sizeof(plain), &plain_len));
    key[0] ^= 0x01;
    TEST_ASSERT_NOT_EQUAL(0, siot_prov_decrypt_envelope(key, raw, raw_len, ID, plain, sizeof(plain),
                                                        &plain_len));
    key[0] ^= 0x01;
    raw[raw_len - 1] ^= 0x01;
    TEST_ASSERT_NOT_EQUAL(0, siot_prov_decrypt_envelope(key, raw, raw_len, ID, plain, sizeof(plain),
                                                        &plain_len));
    TEST_ASSERT_NOT_EQUAL(0, siot_prov_decrypt_envelope(key, raw, 20, ID, plain, sizeof(plain),
                                                        &plain_len)); /* too short */
}
