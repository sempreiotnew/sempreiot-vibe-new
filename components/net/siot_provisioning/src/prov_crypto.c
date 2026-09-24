/* Provisioning crypto — from pocs/components/siot_prov/prov_crypto.c,
 * unchanged apart from the names. Mirrors the app's provisioning_crypto.dart
 * and mocked-device-autoconnect/crypto-helpers.js. */
#include <string.h>

#include "mbedtls/ccm.h"
#include "mbedtls/hkdf.h"
#include "mbedtls/md.h"

#include "siot_provisioning.h"

static const char *HKDF_INFO = "siot-prov-v1";
static const char *SETUP_INFO = "siot-setinst-v1";

void siot_prov_proof(const char *pop, const uint8_t *nonce, size_t nonce_len, char out_hex[65])
{
    uint8_t mac[32];
    const mbedtls_md_info_t *md = mbedtls_md_info_from_type(MBEDTLS_MD_SHA256);
    mbedtls_md_hmac(md, (const uint8_t *)pop, strlen(pop), nonce, nonce_len, mac);

    static const char hex[] = "0123456789abcdef";
    for (int i = 0; i < 32; i++) {
        out_hex[i * 2] = hex[mac[i] >> 4];
        out_hex[i * 2 + 1] = hex[mac[i] & 0x0F];
    }
    out_hex[64] = '\0';
}

void siot_prov_derive_key(const char *pop, const uint8_t *nonce, size_t nonce_len,
                          uint8_t out_key[16])
{
    const mbedtls_md_info_t *md = mbedtls_md_info_from_type(MBEDTLS_MD_SHA256);
    mbedtls_hkdf(md, nonce, nonce_len, (const uint8_t *)pop, strlen(pop),
                 (const uint8_t *)HKDF_INFO, strlen(HKDF_INFO), out_key, 16);
}

void siot_prov_derive_setup_key(const char *id, const char *pop, uint8_t out_key[16])
{
    const mbedtls_md_info_t *md = mbedtls_md_info_from_type(MBEDTLS_MD_SHA256);
    mbedtls_hkdf(md, (const uint8_t *)id, strlen(id), (const uint8_t *)pop, strlen(pop),
                 (const uint8_t *)SETUP_INFO, strlen(SETUP_INFO), out_key, 16);
}

int siot_prov_decrypt_envelope(const uint8_t key16[16], const uint8_t *envelope_raw,
                               size_t envelope_raw_len, const char *aad_id,
                               uint8_t *plaintext_buf, size_t plaintext_buf_len,
                               size_t *plaintext_len)
{
    if (envelope_raw_len < 12 + 16) return -1;

    const uint8_t *nonce2 = envelope_raw;
    const size_t cipher_len = envelope_raw_len - 12 - 16;
    const uint8_t *ciphertext = envelope_raw + 12;
    const uint8_t *tag = envelope_raw + 12 + cipher_len;

    if (cipher_len > plaintext_buf_len) return -2;

    mbedtls_ccm_context ctx;
    mbedtls_ccm_init(&ctx);
    int ret = mbedtls_ccm_setkey(&ctx, MBEDTLS_CIPHER_ID_AES, key16, 128);
    if (ret == 0) {
        ret = mbedtls_ccm_auth_decrypt(&ctx, cipher_len, nonce2, 12,
                                       (const uint8_t *)aad_id, strlen(aad_id),
                                       ciphertext, plaintext_buf, tag, 16);
    }
    mbedtls_ccm_free(&ctx);

    if (ret == 0) *plaintext_len = cipher_len;
    return ret;
}

int siot_prov_encrypt_envelope(const uint8_t key16[16], const char *aad_id,
                               const uint8_t *plaintext, size_t plaintext_len,
                               const uint8_t nonce2[12], uint8_t *out, size_t out_cap,
                               size_t *out_len)
{
    if (out_cap < 12 + plaintext_len + 16) return -2;
    memcpy(out, nonce2, 12);
    mbedtls_ccm_context ctx;
    mbedtls_ccm_init(&ctx);
    int ret = mbedtls_ccm_setkey(&ctx, MBEDTLS_CIPHER_ID_AES, key16, 128);
    if (ret == 0) {
        ret = mbedtls_ccm_encrypt_and_tag(&ctx, plaintext_len, nonce2, 12,
                                          (const uint8_t *)aad_id, strlen(aad_id),
                                          plaintext, out + 12, out + 12 + plaintext_len, 16);
    }
    mbedtls_ccm_free(&ctx);
    if (ret == 0) *out_len = 12 + plaintext_len + 16;
    return ret;
}
