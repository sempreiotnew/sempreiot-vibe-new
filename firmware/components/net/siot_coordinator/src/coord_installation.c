/* From pocs/board/main/installation_msg.c; v3.2: source is the device table. */
#include <string.h>

#include "coord_internal.h"
#include "siot_safr.h"

size_t coord_installation_encode(const siot_installation_t *code,
                                 const siot_devtab_entry_t *entries, size_t n,
                                 uint8_t *out)
{
    size_t off = 0;
    out[off++] = (uint8_t)(code->system_id >> 8);
    out[off++] = (uint8_t)(code->system_id & 0xFF);
    out[off++] = code->channel;

    const size_t ssid_len = strnlen(code->net_ssid, SIOT_SSID_MAX_LEN);
    out[off++] = (uint8_t)ssid_len;
    memcpy(&out[off], code->net_ssid, ssid_len);
    off += ssid_len;

    const size_t name_len = strnlen(code->name, SIOT_NAME_MAX_LEN);
    out[off++] = (uint8_t)name_len;
    memcpy(&out[off], code->name, name_len);
    off += name_len;

    const size_t count_off = off++;
    uint8_t count = 0;
    for (size_t i = 0; i < n; i++) {
        const siot_devtab_entry_t *e = &entries[i];
        if (e->state == SIOT_DEV_RETIRED) continue; /* legacy view: members only */
        const size_t n_len = strnlen(e->name, SIOT_NAME_MAX_LEN);
        const size_t z_len = strnlen(e->zone, SIOT_ZONE_MAX_LEN);
        if (off + 6 + 1 + n_len + 1 + z_len > SAFR_MAX_PAYLOAD) break; /* stop cleanly, never overflow */
        memcpy(&out[off], e->mac, 6);
        off += 6;
        out[off++] = (uint8_t)n_len;
        memcpy(&out[off], e->name, n_len);
        off += n_len;
        out[off++] = (uint8_t)z_len;
        memcpy(&out[off], e->zone, z_len);
        off += z_len;
        count++;
    }
    out[count_off] = count;
    return off;
}
