#include "safr_frame.h"

#include <string.h>

#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "mbedtls/ccm.h"

/* One CCM context shared by the TX scheduler task and the RX task -- must be
 * serialized: concurrent mbedtls_ccm_* calls corrupt the cipher state. */
static mbedtls_ccm_context s_ccm;
static SemaphoreHandle_t s_ccm_lock;
static uint16_t s_system_id;

void safr_frame_init(uint16_t system_id, const uint8_t psk[16])
{
    s_system_id = system_id;
    s_ccm_lock = xSemaphoreCreateMutex();
    mbedtls_ccm_init(&s_ccm);
    mbedtls_ccm_setkey(&s_ccm, MBEDTLS_CIPHER_ID_AES, psk, 128);
}

uint16_t safr_crc16(const uint8_t *data, size_t len)
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

size_t safr_build_frame(uint8_t *out,
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
    out[7] = (uint8_t)(s_system_id >> 8);
    out[8] = (uint8_t)(s_system_id & 0xFF);
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

    xSemaphoreTake(s_ccm_lock, portMAX_DELAY);
    int rc = mbedtls_ccm_encrypt_and_tag(
        &s_ccm,
        payload_len,
        nonce, SAFR_NONCE_LEN,
        out, SAFR_HDR_LEN,              /* AAD = full header */
        payload,
        &out[SAFR_HDR_LEN],             /* ciphertext */
        &out[SAFR_HDR_LEN + payload_len],
        SAFR_TAG_LEN);
    xSemaphoreGive(s_ccm_lock);
    if (rc != 0) return 0;

    const uint16_t crc = safr_crc16(out, total - SAFR_CRC_LEN);
    out[total - 2] = (uint8_t)(crc >> 8);
    out[total - 1] = (uint8_t)(crc & 0xFF);
    return total;
}

bool safr_parse_frame(const uint8_t *buf, size_t len, safr_rx_frame_t *rx)
{
    if (len < SAFR_MIN_FRAME || buf[0] != SAFR_SOF || buf[1] != SAFR_VER) {
        return false;
    }
    const size_t total = ((size_t)buf[2] << 8) | buf[3];
    if (total != len || total > SAFR_MAX_FRAME) return false;

    const uint16_t crc = ((uint16_t)buf[total - 2] << 8) | buf[total - 1];
    if (safr_crc16(buf, total - SAFR_CRC_LEN) != crc) return false;

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
    if (rx->system_id != s_system_id) return false;

    const bool enc = (rx->flags & SAFR_F_ENC) != 0;
    const size_t body_len = total - SAFR_HDR_LEN - SAFR_CRC_LEN;

    if (enc) {
        if (body_len < SAFR_TAG_LEN) return false;
        rx->payload_len = body_len - SAFR_TAG_LEN;
        if (rx->payload_len > SAFR_MAX_PAYLOAD) return false;

        uint8_t nonce[SAFR_NONCE_LEN];
        nonce_from_header(buf, nonce);
        xSemaphoreTake(s_ccm_lock, portMAX_DELAY);
        int rc = mbedtls_ccm_auth_decrypt(
            &s_ccm,
            rx->payload_len,
            nonce, SAFR_NONCE_LEN,
            buf, SAFR_HDR_LEN,
            &buf[SAFR_HDR_LEN],
            rx->payload,
            &buf[SAFR_HDR_LEN + rx->payload_len],
            SAFR_TAG_LEN);
        xSemaphoreGive(s_ccm_lock);
        return rc == 0;
    }

    rx->payload_len = body_len;
    if (rx->payload_len > SAFR_MAX_PAYLOAD) return false;
    memcpy(rx->payload, &buf[SAFR_HDR_LEN], rx->payload_len);
    return true;
}
