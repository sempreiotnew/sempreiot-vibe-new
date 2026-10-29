/* Labels (v3.8, spec §14.2): the LABEL_TABLE page encoder and the ARGS parsers
 * of SET_LABEL / DEL_LABEL / SET_DEVICE_IDS. Pure: host-tested (test_labels.c). */
#include <string.h>

#include "siot_safr.h"

#define LT_HDR_LEN 8 /* kind, page, page_count, total u16, rev u16, count */

static size_t entry_len(const siot_safr_label_t *l)
{
    return 2 + 1 + strnlen(l->name, SAFR_LABEL_NAME_MAX);
}

static uint8_t layout(const siot_safr_label_t *labels, size_t n, size_t *starts, size_t max_pages)
{
    uint8_t pages = 0;
    size_t i = 0;
    do {
        if (pages >= max_pages) break;
        starts[pages++] = i;
        size_t used = LT_HDR_LEN;
        while (i < n && used + entry_len(&labels[i]) <= SAFR_MAX_PAYLOAD) {
            used += entry_len(&labels[i]);
            i++;
        }
    } while (i < n);
    return pages;
}

size_t siot_safr_label_table_encode(uint8_t *out, uint8_t kind, uint16_t rev,
                                    const siot_safr_label_t *labels, size_t n, uint8_t page,
                                    uint8_t *page_count_out)
{
    size_t starts[SAFR_LABEL_CAP + 1];
    const uint8_t pages = layout(labels, n, starts, SAFR_LABEL_CAP + 1);
    if (page_count_out) *page_count_out = pages;
    if (page == 0 || page > pages) return 0;

    const size_t first = starts[page - 1];
    const size_t end = page < pages ? starts[page] : n;
    size_t off = 0;
    out[off++] = kind;
    out[off++] = page;
    out[off++] = pages;
    out[off++] = (uint8_t)(n >> 8);
    out[off++] = (uint8_t)(n & 0xFF);
    out[off++] = (uint8_t)(rev >> 8);
    out[off++] = (uint8_t)(rev & 0xFF);
    const size_t count_off = off++;
    uint8_t count = 0;
    for (size_t i = first; i < end; i++) {
        const size_t len = strnlen(labels[i].name, SAFR_LABEL_NAME_MAX);
        out[off++] = (uint8_t)(labels[i].id >> 8);
        out[off++] = (uint8_t)(labels[i].id & 0xFF);
        out[off++] = (uint8_t)len;
        memcpy(&out[off], labels[i].name, len);
        off += len;
        count++;
    }
    out[count_off] = count;
    return off;
}

static bool kind_ok(uint8_t kind)
{
    return kind == SAFR_LABEL_ZONE || kind == SAFR_LABEL_ADDRESS;
}

bool siot_safr_set_label_decode(const uint8_t *a, size_t alen, uint8_t *kind, uint16_t *id,
                                char name[SAFR_LABEL_NAME_MAX + 1])
{
    if (alen < 4) return false;
    const size_t len = a[3];
    if (len == 0 || len > SAFR_LABEL_NAME_MAX || 4 + len != alen) return false;
    *kind = a[0];
    *id = (uint16_t)(((uint16_t)a[1] << 8) | a[2]);
    if (!kind_ok(*kind) || *id == SAFR_LABEL_ID_NONE) return false;
    memcpy(name, &a[4], len);
    name[len] = '\0';
    return true;
}

bool siot_safr_del_label_decode(const uint8_t *a, size_t alen, uint8_t *kind, uint16_t *id)
{
    if (alen != 3) return false;
    *kind = a[0];
    *id = (uint16_t)(((uint16_t)a[1] << 8) | a[2]);
    return kind_ok(*kind) && *id != SAFR_LABEL_ID_NONE;
}

bool siot_safr_set_device_ids_decode(const uint8_t *a, size_t alen, uint8_t mac[6],
                                     uint16_t *zone_id, uint16_t *address_id)
{
    if (alen != 10) return false;
    memcpy(mac, a, 6);
    *zone_id = (uint16_t)(((uint16_t)a[6] << 8) | a[7]);
    *address_id = (uint16_t)(((uint16_t)a[8] << 8) | a[9]);
    return true;
}
