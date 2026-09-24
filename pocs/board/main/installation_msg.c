#include "installation_msg.h"

#include <string.h>

#include "safr_proto.h"

size_t installation_msg_encode(const board_state_t *st, uint8_t *out)
{
    size_t off = 0;

    out[off++] = (uint8_t)(st->inst.system_id >> 8);
    out[off++] = (uint8_t)(st->inst.system_id & 0xFF);
    out[off++] = st->inst.channel;

    const size_t ssid_len = strnlen(st->inst.net_ssid, SIOT_SSID_MAX_LEN);
    out[off++] = (uint8_t)ssid_len;
    memcpy(&out[off], st->inst.net_ssid, ssid_len);
    off += ssid_len;

    const size_t name_len = strnlen(st->inst.name, SIOT_NAME_MAX_LEN);
    out[off++] = (uint8_t)name_len;
    memcpy(&out[off], st->inst.name, name_len);
    off += name_len;

    /* KNOWN GAP (see README.md): st->enrolled[] is never actually populated
     * today — siot_prov's handle_enroll() (prov_http.c) only logs the
     * /enroll count, it doesn't hand the list back to board. This always
     * encodes ENROLLED_COUNT=0 until that's wired up. */
    size_t count_off = off++;
    uint8_t count = 0;
    for (int i = 0; i < BOARD_MAX_ENROLLED; i++) {
        if (!st->enrolled[i].used) continue;
        const board_enrolled_t *e = &st->enrolled[i];
        const size_t n_len = strnlen(e->name, SIOT_NAME_MAX_LEN);
        const size_t z_len = strnlen(e->zone, SIOT_ZONE_MAX_LEN);
        const size_t entry_len = 6 + 1 + n_len + 1 + z_len;
        /* Defensive: BOARD_MAX_ENROLLED (8) is an array capacity, not a
         * promise every slot fits in one SAFR frame — round 1 only ever
         * populates 2 (POC-BRIEF §7 step 2), but stop cleanly rather than
         * overflow `out` if that ever changes. */
        if (off + entry_len > SAFR_MAX_PAYLOAD) break;

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
