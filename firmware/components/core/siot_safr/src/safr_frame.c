/* SAFR v3 frame codec — ported from pocs/components/safr/safr_frame.c
 * (itself from mocked-device/main/safr_frame.c). Behaviour unchanged:
 *   - safr_build_frame / safr_parse_frame / safr_crc16 bodies as in the POC
 *   - SAFR_MAX_FRAME is 250 instead of 256 (spec §3, v3.1)
 *   - parse reports WHY it failed (bad frame / foreign / auth) so siot_safr
 *     can keep the diagnostics of spec §3.3 / §10; the POC returned a bool
 *   - the mutex is behind safr_port.h so the same file builds on linux
 */
#include <string.h>

#include "mbedtls/ccm.h"

#include "safr_internal.h"
#include "safr_port.h"

const uint8_t SAFR_CENTRAL_MAC[6] = {0x00, 0x00, 0x00, 0x00, 0x00, 0x01};
const uint8_t SAFR_BCAST_MAC[6]   = {0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF};

/* One CCM context shared by the TX path and the RX task -- must be
 * serialized: concurrent mbedtls_ccm_* calls corrupt the cipher state. */
static mbedtls_ccm_context s_ccm;
static safr_lock_t s_ccm_lock;
static bool s_ccm_lock_ready;
static bool s_ccm_ready;   /* a key is installed */
static uint16_t s_system_id;

int safr_codec_init(uint16_t system_id, const uint8_t psk[16])
{
    s_system_id = system_id;
    if (!s_ccm_lock_ready) {
        safr_lock_init(&s_ccm_lock);
        s_ccm_lock_ready = true;
    }
    safr_lock(&s_ccm_lock);
    if (s_ccm_ready) mbedtls_ccm_free(&s_ccm); /* re-init after (re)provisioning */
    mbedtls_ccm_init(&s_ccm);
    const int rc = mbedtls_ccm_setkey(&s_ccm, MBEDTLS_CIPHER_ID_AES, psk, 128);
    s_ccm_ready = (rc == 0);
    safr_unlock(&s_ccm_lock);
    return rc;
}

uint16_t siot_safr_crc16(const uint8_t *data, size_t len)
{
    uint16_t crc = 0xFFFF;
    for (size_t i = 0; i < len; i++) {
        crc ^= (uint16_t)data[i] << 8;
        for (int b = 0; b < 8; b++) {
            crc = (crc & 0x8000) ? (uint16_t)((crc << 1) ^ 0x1021)
                                 : (uint16_t)(crc << 1);
        }
    }
    return crc;
}

/* Nonce = SRC_MAC(6) ‖ BOOT_CTR(2) ‖ MSG_CTR(4), all straight from the header
 * (v3 offsets: SRC_MAC at 9, BOOT_CTR‖MSG_CTR at 24 -- spec §4) */
static void nonce_from_header(const uint8_t *hdr, uint8_t nonce[SAFR_NONCE_LEN])
{
    memcpy(nonce, &hdr[9], 6);       /* SRC_MAC */
    memcpy(&nonce[6], &hdr[24], 6);  /* BOOT_CTR ‖ MSG_CTR */
}

/* Shared bodies: `ccm` is the installed context (s_ccm) or a temporary one
 * for the setup channel (spec §3.1); `lock` is NULL for a private context. */
static size_t build_with_ctx(mbedtls_ccm_context *ccm, safr_lock_t *lock, uint16_t system_id,
                             uint8_t *out, uint8_t msg_type, uint16_t msg_id,
                             const uint8_t src_mac[6], const uint8_t dst_mac[6],
                             uint8_t ttl, uint8_t hops, uint8_t flags,
                             uint16_t boot_ctr, uint32_t msg_ctr,
                             const uint8_t *payload, size_t payload_len)
{
    if (payload_len > SAFR_MAX_PAYLOAD) return 0;

    flags |= SAFR_F_ENC;
    const size_t total =
        SAFR_HDR_LEN + payload_len + SAFR_TAG_LEN + SAFR_CRC_LEN;

    out[0] = SAFR_SOF;
    out[1] = SAFR_VER;
    out[2] = (uint8_t)(total >> 8);
    out[3] = (uint8_t)(total & 0xFF);
    out[4] = msg_type;
    out[5] = (uint8_t)(msg_id >> 8);
    out[6] = (uint8_t)(msg_id & 0xFF);
    out[7] = (uint8_t)(system_id >> 8);
    out[8] = (uint8_t)(system_id & 0xFF);
    memcpy(&out[9], src_mac, 6);
    memcpy(&out[15], dst_mac, 6);
    out[21] = ttl;
    out[22] = hops;
    out[23] = flags;
    out[24] = (uint8_t)(boot_ctr >> 8);
    out[25] = (uint8_t)(boot_ctr & 0xFF);
    out[26] = (uint8_t)(msg_ctr >> 24);
    out[27] = (uint8_t)(msg_ctr >> 16);
    out[28] = (uint8_t)(msg_ctr >> 8);
    out[29] = (uint8_t)(msg_ctr & 0xFF);

    uint8_t nonce[SAFR_NONCE_LEN];
    nonce_from_header(out, nonce);

    if (lock) safr_lock(lock);
    int rc = mbedtls_ccm_encrypt_and_tag(
        ccm,
        payload_len,
        nonce, SAFR_NONCE_LEN,
        out, SAFR_HDR_LEN,              /* AAD = full header */
        payload,
        &out[SAFR_HDR_LEN],             /* ciphertext */
        &out[SAFR_HDR_LEN + payload_len],
        SAFR_TAG_LEN);
    if (lock) safr_unlock(lock);
    if (rc != 0) return 0;

    const uint16_t crc = siot_safr_crc16(out, total - SAFR_CRC_LEN);
    out[total - 2] = (uint8_t)(crc >> 8);
    out[total - 1] = (uint8_t)(crc & 0xFF);
    return total;
}

static siot_safr_parse_result_t parse_with_ctx(mbedtls_ccm_context *ccm, safr_lock_t *lock,
                                               bool ccm_ready, uint16_t system_id,
                                               const uint8_t *buf, size_t len,
                                               siot_safr_frame_t *rx)
{
    if (len < SAFR_MIN_FRAME || buf[0] != SAFR_SOF || buf[1] != SAFR_VER) {
        return SIOT_SAFR_PARSE_BAD_FRAME;
    }
    const size_t total = ((size_t)buf[2] << 8) | buf[3];
    if (total != len || total > SAFR_MAX_FRAME) return SIOT_SAFR_PARSE_BAD_FRAME;

    const uint16_t crc = ((uint16_t)buf[total - 2] << 8) | buf[total - 1];
    if (siot_safr_crc16(buf, total - SAFR_CRC_LEN) != crc) return SIOT_SAFR_PARSE_BAD_FRAME;

    rx->msg_type  = buf[4];
    rx->msg_id    = ((uint16_t)buf[5] << 8) | buf[6];
    rx->system_id = ((uint16_t)buf[7] << 8) | buf[8];
    memcpy(rx->src_mac, &buf[9], 6);
    memcpy(rx->dst_mac, &buf[15], 6);
    rx->ttl      = buf[21];
    rx->hops     = buf[22];
    rx->flags    = buf[23];
    rx->boot_ctr = ((uint16_t)buf[24] << 8) | buf[25];
    rx->msg_ctr  = ((uint32_t)buf[26] << 24) | ((uint32_t)buf[27] << 16) |
                   ((uint32_t)buf[28] << 8) | buf[29];

    /* Site separation (spec §3.1): frames from another installation are
     * dropped before any decryption attempt. */
    if (rx->system_id != system_id) return SIOT_SAFR_PARSE_FOREIGN;

    const bool enc = (rx->flags & SAFR_F_ENC) != 0;
    const size_t body_len = total - SAFR_HDR_LEN - SAFR_CRC_LEN;

    if (enc) {
        if (body_len < SAFR_TAG_LEN) return SIOT_SAFR_PARSE_BAD_FRAME;
        rx->payload_len = body_len - SAFR_TAG_LEN;
        if (rx->payload_len > SAFR_MAX_PAYLOAD) return SIOT_SAFR_PARSE_BAD_FRAME;
        if (!ccm_ready) return SIOT_SAFR_PARSE_AUTH_FAILED;

        uint8_t nonce[SAFR_NONCE_LEN];
        nonce_from_header(buf, nonce);
        if (lock) safr_lock(lock);
        int rc = mbedtls_ccm_auth_decrypt(
            ccm,
            rx->payload_len,
            nonce, SAFR_NONCE_LEN,
            buf, SAFR_HDR_LEN,
            &buf[SAFR_HDR_LEN],
            rx->payload,
            &buf[SAFR_HDR_LEN + rx->payload_len],
            SAFR_TAG_LEN);
        if (lock) safr_unlock(lock);
        return rc == 0 ? SIOT_SAFR_PARSE_OK : SIOT_SAFR_PARSE_AUTH_FAILED;
    }

    rx->payload_len = body_len;
    if (rx->payload_len > SAFR_MAX_PAYLOAD) return SIOT_SAFR_PARSE_BAD_FRAME;
    memcpy(rx->payload, &buf[SAFR_HDR_LEN], rx->payload_len);
    return SIOT_SAFR_PARSE_OK;
}

size_t siot_safr_build_frame(uint8_t *out,
                             uint8_t msg_type,
                             uint16_t msg_id,
                             const uint8_t src_mac[6],
                             const uint8_t dst_mac[6],
                             uint8_t ttl,
                             uint8_t hops,
                             uint8_t flags,
                             uint16_t boot_ctr,
                             uint32_t msg_ctr,
                             const uint8_t *payload,
                             size_t payload_len)
{
    if (!s_ccm_ready) return 0;
    return build_with_ctx(&s_ccm, &s_ccm_lock, s_system_id, out, msg_type, msg_id, src_mac, dst_mac,
                          ttl, hops, flags, boot_ctr, msg_ctr, payload, payload_len);
}

siot_safr_parse_result_t siot_safr_parse_frame(const uint8_t *buf, size_t len,
                                               siot_safr_frame_t *rx)
{
    return parse_with_ctx(&s_ccm, &s_ccm_lock, s_ccm_ready, s_system_id, buf, len, rx);
}

/* ---- explicit-key variants (setup channel, spec §3.1 v3.2) ------------- */

size_t siot_safr_build_frame_with(uint16_t system_id, const uint8_t key[16], uint8_t *out,
                                  uint8_t msg_type, uint16_t msg_id,
                                  const uint8_t src_mac[6], const uint8_t dst_mac[6],
                                  uint8_t ttl, uint8_t hops, uint8_t flags,
                                  uint16_t boot_ctr, uint32_t msg_ctr,
                                  const uint8_t *payload, size_t payload_len)
{
    mbedtls_ccm_context ccm;
    mbedtls_ccm_init(&ccm);
    if (mbedtls_ccm_setkey(&ccm, MBEDTLS_CIPHER_ID_AES, key, 128) != 0) {
        mbedtls_ccm_free(&ccm);
        return 0;
    }
    const size_t n = build_with_ctx(&ccm, NULL, system_id, out, msg_type, msg_id, src_mac, dst_mac,
                                    ttl, hops, flags, boot_ctr, msg_ctr, payload, payload_len);
    mbedtls_ccm_free(&ccm);
    return n;
}

siot_safr_parse_result_t siot_safr_parse_frame_with(uint16_t system_id, const uint8_t key[16],
                                                    const uint8_t *buf, size_t len,
                                                    siot_safr_frame_t *rx)
{
    mbedtls_ccm_context ccm;
    mbedtls_ccm_init(&ccm);
    const bool ready = mbedtls_ccm_setkey(&ccm, MBEDTLS_CIPHER_ID_AES, key, 128) == 0;
    const siot_safr_parse_result_t r = parse_with_ctx(&ccm, NULL, ready, system_id, buf, len, rx);
    mbedtls_ccm_free(&ccm);
    return r;
}
