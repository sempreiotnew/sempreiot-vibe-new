/* Registry + reassembler. The reassembler is the loop every byte-stream
 * backend in the POC carried (node_mesh.c, tcp_link.c, board_main.c), with
 * the CRC checked here so a false SOF costs exactly one byte (spec §10). */
#include <string.h>

#include "siot_link.h"

static const siot_link_ops_t *s_ops[SIOT_LINK_KIND_MAX];
static siot_link_rx_cb_t s_rx;
static void *s_rx_ctx;

esp_err_t siot_link_register(siot_link_kind_t kind, const siot_link_ops_t *ops)
{
    if (kind >= SIOT_LINK_KIND_MAX || ops == NULL || ops->send == NULL) return ESP_ERR_INVALID_ARG;
    s_ops[kind] = ops;
    return ESP_OK;
}

esp_err_t siot_link_set_rx(siot_link_rx_cb_t cb, void *ctx)
{
    s_rx = cb;
    s_rx_ctx = ctx;
    return ESP_OK;
}

esp_err_t siot_link_start(siot_link_kind_t kind)
{
    if (kind >= SIOT_LINK_KIND_MAX || s_ops[kind] == NULL) return ESP_ERR_INVALID_STATE;
    return s_ops[kind]->start ? s_ops[kind]->start() : ESP_OK;
}

esp_err_t siot_link_stop(siot_link_kind_t kind)
{
    if (kind >= SIOT_LINK_KIND_MAX || s_ops[kind] == NULL) return ESP_ERR_INVALID_STATE;
    return s_ops[kind]->stop ? s_ops[kind]->stop() : ESP_OK;
}

esp_err_t siot_link_send(siot_link_kind_t kind, const uint8_t *dst_mac,
                         const uint8_t *frame, size_t len)
{
    if (kind >= SIOT_LINK_KIND_MAX || s_ops[kind] == NULL) return ESP_ERR_INVALID_STATE;
    return s_ops[kind]->send(dst_mac, frame, len);
}

bool siot_link_is_up(siot_link_kind_t kind)
{
    if (kind >= SIOT_LINK_KIND_MAX || s_ops[kind] == NULL || s_ops[kind]->is_up == NULL) return false;
    return s_ops[kind]->is_up();
}

int siot_link_rssi(siot_link_kind_t kind)
{
    if (kind >= SIOT_LINK_KIND_MAX || s_ops[kind] == NULL || s_ops[kind]->rssi == NULL) return 0;
    return s_ops[kind]->rssi();
}

void siot_link_deliver(siot_link_kind_t kind, const uint8_t *frame, size_t len)
{
    if (s_rx) s_rx(kind, frame, len, s_rx_ctx);
}

/* ---- reassembler ------------------------------------------------------ */

void siot_link_reasm_reset(siot_link_reasm_t *r)
{
    r->len = 0;
}

size_t siot_link_reasm_feed(siot_link_reasm_t *r, siot_link_kind_t kind, const uint8_t *chunk, size_t n)
{
    if (n > sizeof(r->acc)) { chunk += n - sizeof(r->acc); n = sizeof(r->acc); }
    if (r->len + n > sizeof(r->acc)) r->len = 0; /* overflow guard */
    memcpy(r->acc + r->len, chunk, n);
    r->len += n;

    size_t delivered = 0;
    size_t pos = 0;
    while (r->len - pos >= SAFR_MIN_FRAME) {
        const uint8_t *p = &r->acc[pos];
        if (p[0] != SAFR_SOF) { pos++; continue; }
        const size_t flen = ((size_t)p[2] << 8) | p[3];
        if (flen < SAFR_MIN_FRAME || flen > SAFR_MAX_FRAME) { pos++; continue; }
        if (r->len - pos < flen) break; /* wait for more bytes */
        const uint16_t crc = ((uint16_t)p[flen - 2] << 8) | p[flen - 1];
        if (siot_safr_crc16(p, flen - SAFR_CRC_LEN) != crc) { pos++; continue; } /* false SOF / noise */
        siot_link_deliver(kind, p, flen);
        delivered++;
        pos += flen;
    }
    memmove(r->acc, r->acc + pos, r->len - pos);
    r->len -= pos;
    return delivered;
}
