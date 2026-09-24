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
#include "sdkconfig.h"

#ifdef __cplusplus
extern "C" {
#endif

#ifndef CONFIG_IDF_TARGET_LINUX
/* Requires siot_identity_init() (valid identity), siot_evbus_init() and
 * siot_config_init() to have run. Brings up esp_netif / esp_event / Wi-Fi
 * AP + the HTTP server. Setup mode is exclusive: the unit reboots out of it. */
esp_err_t siot_provisioning_start(bool is_board);

/* Board: where /enroll entries go. When set, each `{mac, name, zone}` is
 * handed to `sink` (the coordinator's device table, lifecycle §3.2 "expected")
 * instead of the legacy ≤ 8 enrolled blob. Call before siot_provisioning_start(). */
typedef esp_err_t (*siot_prov_enroll_sink_t)(const uint8_t mac[6], const char *name, const char *zone);
void siot_provisioning_set_enroll_sink(siot_prov_enroll_sink_t sink);

/* Admin window (lifecycle §11): the HTTP half only — GET /info, POST /identify,
 * GET /code (the code encrypted for whoever proved the sticker), GET /status.
 * The caller swaps the Wi-Fi AP (siot_link_mesh_board_suspend/resume) and
 * owns the 5-minute timer; `on_delivered` fires once /code succeeded. Requires
 * a stored code. */
esp_err_t siot_provisioning_admin_start(void (*on_delivered)(void));
void siot_provisioning_admin_stop(void);
#endif

/* ---- crypto (POC-BRIEF §5) ------------------------------------------- */

/* proof = hex(HMAC-SHA256(key = pop, msg = nonce)); out_hex[65]. */
void siot_prov_proof(const char *pop, const uint8_t *nonce, size_t nonce_len, char out_hex[65]);

/* key = HKDF-SHA256(ikm = pop, salt = nonce, info = "siot-prov-v1", L = 16). */
void siot_prov_derive_key(const char *pop, const uint8_t *nonce, size_t nonce_len,
                          uint8_t out_key[16]);

/* Setup-channel key (spec §3.1 v3.2): HKDF-SHA256(ikm = pop, salt = id,
 * info = "siot-setinst-v1", L = 16). The tablet derives the same from the
 * board sticker for SET_INSTALLATION / GET_CODE under SYSTEM_ID 0x0000. */
void siot_prov_derive_setup_key(const char *id, const char *pop, uint8_t out_key[16]);

/* The reverse direction (lifecycle §11 admin window, GET /code): the board
 * encrypts the code for a phone that proved the sticker. Same layout as
 * /provision's envelope: nonce2(12) ‖ CCM(key, nonce2, aad = id, plaintext) ‖ tag(16).
 * `out_cap` >= 12 + plaintext_len + 16. 0 on success. */
int siot_prov_encrypt_envelope(const uint8_t key16[16], const char *aad_id,
                               const uint8_t *plaintext, size_t plaintext_len,
                               const uint8_t nonce2[12], uint8_t *out, size_t out_cap,
                               size_t *out_len);

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
