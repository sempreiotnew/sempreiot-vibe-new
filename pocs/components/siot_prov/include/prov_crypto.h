/*
 * Provisioning crypto — pocs/POC-BRIEF.md §5, docs/safr/protocol-safr-v3.md style.
 * Mirrors mocked-device-autoconnect/crypto-helpers.js and the Dart side
 * (lib/features/provisioning/domain/prov_crypto.dart) so all three
 * implementations are checked against the same vectors.json.
 */
#pragma once

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* proof = hex(HMAC-SHA256(key = pop, msg = nonce)), out_hex[65] (64 + NUL). */
void siot_crypto_proof(const char *pop, const uint8_t *nonce, size_t nonce_len,
                        char out_hex[65]);

/* key = HKDF-SHA256(ikm = pop, salt = nonce, info = "siot-prov-v1", L = 16). */
void siot_crypto_derive_key(const char *pop, const uint8_t *nonce,
                             size_t nonce_len, uint8_t out_key[16]);

/*
 * envelope = base64(nonce2(12) || AES-128-CCM(key, nonce2, aad=id, code_json) || tag(16))
 *
 * Decrypts and verifies in place. `plaintext_buf` must be at least
 * `envelope_raw_len - 12 - 16` bytes; on success `*plaintext_len` is set.
 * Returns 0 on success (tag verified), non-zero otherwise (bad envelope).
 */
int siot_crypto_decrypt_envelope(const uint8_t *key16,
                                  const uint8_t *envelope_raw,
                                  size_t envelope_raw_len,
                                  const char *aad_id,
                                  uint8_t *plaintext_buf,
                                  size_t plaintext_buf_len,
                                  size_t *plaintext_len);

#ifdef __cplusplus
}
#endif
