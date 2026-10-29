/* DEVICE_TABLE encoder (spec §7.12). Pages are cut so every page fits the
 * payload cap; the page layout is recomputed on every call (the table is
 * small and this runs once per GET_DEVICE_TABLE). */
#include <string.h>

#include "coord_internal.h"
#include "siot_safr.h"
#include "siot_util.h"

#define DT_HDR_LEN 5 /* page, page_count, total u16, count */

/* format: 0 = v3.2 entry · 1 = + PRODUCT ‖ HW_REV ‖ FW (v3.5) · 2 = + ZONE_ID ‖
 * ADDRESS_ID ‖ LINK (v3.8). The zone slot is reserved since v3.8: always length 0. */
static size_t entry_len(const siot_devtab_entry_t *e, uint8_t format)
{
    size_t len = 6 + 1 + 1 + 1 + 2 + 1 + strnlen(e->name, SIOT_NAME_MAX_LEN) + 1;
    if (format >= 1) len += 4 + strnlen(e->fw, SAFR_FW_MAX_LEN);
    if (format >= 2) len += 2 + 2 + 1;
    return len;
}

/* First entry index of each page; returns page count. */
static uint8_t layout(const siot_devtab_entry_t *entries, size_t n, uint8_t format, size_t *starts,
                      size_t max_pages)
{
    uint8_t pages = 0;
    size_t i = 0;
    do {
        if (pages >= max_pages) break;
        starts[pages++] = i;
        size_t used = DT_HDR_LEN;
        while (i < n && used + entry_len(&entries[i], format) <= SAFR_MAX_PAYLOAD) {
            used += entry_len(&entries[i], format);
            i++;
        }
    } while (i < n);
    return pages;
}

size_t coord_devtable_encode_page(const siot_devtab_entry_t *entries, size_t n, int64_t now_ms,
                                  uint8_t page, uint8_t format, uint8_t *page_count_out, uint8_t *out)
{
    size_t starts[256];
    const uint8_t pages = layout(entries, n, format, starts, 255);
    if (page_count_out) *page_count_out = pages;
    if (page == 0 || page > pages) return 0;

    const size_t first = starts[page - 1];
    const size_t end = page < pages ? starts[page] : n;

    size_t off = 0;
    out[off++] = page;
    out[off++] = pages;
    siot_put_u16(&out[off], (uint16_t)n);
    off += 2;
    const size_t count_off = off++;
    uint8_t count = 0;
    for (size_t i = first; i < end; i++) {
        const siot_devtab_entry_t *e = &entries[i];
        const size_t n_len = strnlen(e->name, SIOT_NAME_MAX_LEN);
        memcpy(&out[off], e->mac, 6);
        off += 6;
        out[off++] = e->role;
        out[off++] = e->state;
        out[off++] = e->flags;
        uint16_t age = SAFR_NA_U16; /* never heard this boot */
        if (e->last_seen_ms >= 0) {
            const int64_t a = (now_ms - e->last_seen_ms) / 1000;
            age = a > 0xFFFE ? 0xFFFE : (uint16_t)(a < 0 ? 0 : a);
        }
        siot_put_u16(&out[off], age);
        off += 2;
        out[off++] = (uint8_t)n_len;
        memcpy(&out[off], e->name, n_len);
        off += n_len;
        out[off++] = 0; /* ZONE_LEN: reserved since v3.8 */
        if (format >= 1) off += siot_safr_put_product(&out[off], e->product, e->hw_rev, e->fw);
        if (format >= 2) {
            siot_put_u16(&out[off], e->zone_id);
            off += 2;
            siot_put_u16(&out[off], e->address_id);
            off += 2;
            out[off++] = e->link;
        }
        count++;
    }
    uint8_t count_byte = count;
    if (format >= 1) count_byte |= COORD_DT_F_PRODUCT;
    if (format >= 2) count_byte |= COORD_DT_F_LABELS;
    out[count_off] = count_byte;
    return off;
}
