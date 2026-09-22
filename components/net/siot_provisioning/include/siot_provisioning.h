/* siot_provisioning — setup mode (brief §7): raises SIOT-SETUP-<id> (WPA2 =
 * pop) with the HTTP contract of POC-BRIEF §5 and stores the code the
 * installer app pushes.
 *
 *   GET  /info       {id, mac, model, fw, state, nonce}
 *   POST /identify   {id, proof}                 200 {ok} / 403 proof_mismatch
 *   POST /provision  {envelope, name, zone, epoch} 202 / 409 not_identified / 400 bad_envelope
 *   POST /enroll     [{mac, id, name, zone}]      board only, persisted at once
 *   GET  /status     {state, detail}
 *
 * After /provision: state "stored", SIOT_EVT_PROVISIONED on the bus, reboot
 * into normal mode once /status was polled once or after 30 s.
 * AC units keep the setup network up indefinitely (blueprint §2; the 10 min
 * timeout is for battery units, Phase 2).
 *
 * Ported from pocs/components/siot_prov (wifi_softap.c, prov_http.c,
 * prov_crypto.c). `fw` now comes from siot_version, the code is stored via
 * siot_config, the identity read via siot_identity.
 *
 * The crypto half (proof, HKDF key, CCM envelope) is exposed for test/host —
 * it is checked against the app's provisioning_crypto_vectors_test.dart.
 */
#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

#ifndef CONFIG_IDF_TARGET_LINUX
/* Requires siot_identity_init() (valid identity), siot_evbus_init() and
 * siot_config_init() to have run. Brings up esp_netif / esp_event / Wi-Fi
 * AP + the HTTP server. Setup mode is exclusive: the unit reboots out of it. */
esp_err_t siot_provisioning_start(bool is_board);
#endif

/* ---- crypto (POC-BRIEF §5) ------------------------------------------- */

/* proof = hex(HMAC-SHA256(key = pop, msg = nonce)); out_hex[65]. */
void siot_prov_proof(const char *pop, const uint8_t *nonce, size_t nonce_len, char out_hex[65]);

/* key = HKDF-SHA256(ikm = pop, salt = nonce, info = "siot-prov-v1", L = 16). */
void siot_prov_derive_key(const char *pop, const uint8_t *nonce, size_t nonce_len,
                          uint8_t out_key[16]);

/* envelope_raw = nonce2(12) ‖ AES-128-CCM(key, nonce2, aad = id, code_json) ‖ tag(16)
 * (already base64-decoded). Decrypts into plaintext_buf; 0 on success (tag
 * verified), non-zero otherwise. */
int siot_prov_decrypt_envelope(const uint8_t key16[16], const uint8_t *envelope_raw,
                               size_t envelope_raw_len, const char *aad_id,
                               uint8_t *plaintext_buf, size_t plaintext_buf_len,
                               size_t *plaintext_len);

#ifdef __cplusplus
}
#endif
