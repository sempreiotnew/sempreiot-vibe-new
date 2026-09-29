#include "siot_ota_proto.h"

#include <string.h>

#include "siot_util.h"

/* ---- small pieces ------------------------------------------------------------ */

static bool family_ok(uint8_t f)
{
    return f == SAFR_FAMILY_BOARD || f == SAFR_FAMILY_NODE || f == SAFR_FAMILY_LEAF;
}

static size_t put_str(uint8_t *p, const char *s, size_t max)
{
    const size_t n = s ? strnlen(s, max) : 0;
    p[0] = (uint8_t)n;
    if (n) memcpy(&p[1], s, n);
    return 1 + n;
}

/* Reads LEN ‖ bytes at p[*off]; advances *off. false = past the end or too long. */
static bool get_str(const uint8_t *p, size_t len, size_t *off, char *out, size_t max)
{
    if (*off >= len) return false;
    const size_t n = p[*off];
    if (n > max || *off + 1 + n > len) return false;
    memcpy(out, &p[*off + 1], n);
    out[n] = '\0';
    *off += 1 + n;
    return true;
}

/* ---- image: OTA_PUSH_BEGIN and OTA_OFFER ---------------------------------------- */

size_t siot_ota_push_begin_encode(uint8_t *p, const siot_ota_image_t *img)
{
    size_t off = 0;
    p[off++] = img->family;
    siot_put_u32(&p[off], img->size); off += 4;
    memcpy(&p[off], img->sha256, SIOT_OTA_SHA_LEN); off += SIOT_OTA_SHA_LEN;
    siot_put_u16(&p[off], img->chunk); off += 2;
    p[off++] = img->flags;
    off += put_str(&p[off], img->version, SIOT_OTA_VER_MAX_LEN);
    return off;
}

bool siot_ota_push_begin_decode(const uint8_t *p, size_t len, siot_ota_image_t *img)
{
    if (len < 1 + 4 + SIOT_OTA_SHA_LEN + 2 + 1 + 1) return false;
    memset(img, 0, sizeof(*img));
    size_t off = 0;
    img->family = p[off++];
    img->size = siot_get_u32(&p[off]); off += 4;
    memcpy(img->sha256, &p[off], SIOT_OTA_SHA_LEN); off += SIOT_OTA_SHA_LEN;
    img->chunk = siot_get_u16(&p[off]); off += 2;
    img->flags = p[off++];
    if (!get_str(p, len, &off, img->version, SIOT_OTA_VER_MAX_LEN) || off != len) return false;
    return family_ok(img->family) && img->size > 0 && img->chunk > 0 && img->chunk <= SIOT_OTA_CHUNK_MAX &&
           img->version[0] != '\0';
}

size_t siot_ota_offer_encode(uint8_t *p, const siot_ota_image_t *img)
{
    size_t off = 0;
    p[off++] = img->family;
    siot_put_u32(&p[off], img->size); off += 4;
    memcpy(&p[off], img->sha256, SIOT_OTA_SHA_LEN); off += SIOT_OTA_SHA_LEN;
    siot_put_u16(&p[off], img->deadline_s); off += 2;
    p[off++] = img->flags;
    off += put_str(&p[off], img->version, SIOT_OTA_VER_MAX_LEN);
    return off;
}

bool siot_ota_offer_decode(const uint8_t *p, size_t len, siot_ota_image_t *img)
{
    if (len < 1 + 4 + SIOT_OTA_SHA_LEN + 2 + 1 + 1) return false;
    memset(img, 0, sizeof(*img));
    size_t off = 0;
    img->family = p[off++];
    img->size = siot_get_u32(&p[off]); off += 4;
    memcpy(img->sha256, &p[off], SIOT_OTA_SHA_LEN); off += SIOT_OTA_SHA_LEN;
    img->deadline_s = siot_get_u16(&p[off]); off += 2;
    img->flags = p[off++];
    if (!get_str(p, len, &off, img->version, SIOT_OTA_VER_MAX_LEN) || off != len) return false;
    return family_ok(img->family) && img->size > 0 && img->version[0] != '\0';
}

/* ---- OTA_PUSH_CHUNK -------------------------------------------------------------- */

size_t siot_ota_chunk_encode(uint8_t *p, const siot_ota_chunk_t *c)
{
    siot_put_u32(&p[0], c->seq);
    siot_put_u16(&p[4], c->len);
    siot_put_u32(&p[6], c->crc32);
    return SIOT_OTA_CHUNK_HDR_LEN;
}

bool siot_ota_chunk_decode(const uint8_t *p, size_t len, siot_ota_chunk_t *c)
{
    if (len != SIOT_OTA_CHUNK_HDR_LEN) return false;
    c->seq = siot_get_u32(&p[0]);
    c->len = siot_get_u16(&p[4]);
    c->crc32 = siot_get_u32(&p[6]);
    return c->len > 0 && c->len <= SIOT_OTA_CHUNK_MAX;
}

/* ---- OTA_PUSH_RESULT -------------------------------------------------------------- */

size_t siot_ota_push_result_encode(uint8_t *p, const siot_ota_push_result_t *r)
{
    size_t off = 0;
    p[off++] = r->phase;
    p[off++] = r->reason;
    p[off++] = r->family;
    siot_put_u32(&p[off], r->next_seq); off += 4;
    off += put_str(&p[off], r->version, SIOT_OTA_VER_MAX_LEN);
    return off;
}

bool siot_ota_push_result_decode(const uint8_t *p, size_t len, siot_ota_push_result_t *r)
{
    if (len < 3 + 4 + 1) return false;
    memset(r, 0, sizeof(*r));
    size_t off = 0;
    r->phase = p[off++];
    r->reason = p[off++];
    r->family = p[off++];
    r->next_seq = siot_get_u32(&p[off]); off += 4;
    if (!get_str(p, len, &off, r->version, SIOT_OTA_VER_MAX_LEN) || off != len) return false;
    return r->phase <= SIOT_OTA_PUSH_FAILED;
}

/* ---- OTA_STATUS / OTA_RESULT -------------------------------------------------------- */

size_t siot_ota_status_encode(uint8_t *p, const siot_ota_status_t *s)
{
    p[0] = s->state;
    p[1] = s->percent > 100 ? 100 : s->percent;
    return SIOT_OTA_STATUS_LEN;
}

bool siot_ota_status_decode(const uint8_t *p, size_t len, siot_ota_status_t *s)
{
    if (len != SIOT_OTA_STATUS_LEN) return false;
    s->state = p[0];
    s->percent = p[1];
    return s->state < SIOT_OTA_U__COUNT && s->percent <= 100;
}

size_t siot_ota_result_encode(uint8_t *p, const siot_ota_result_t *r)
{
    size_t off = 0;
    p[off++] = r->ok ? 1 : 0;
    p[off++] = r->reason;
    siot_put_u16(&p[off], r->awake_s); off += 2;
    off += put_str(&p[off], r->version, SIOT_OTA_VER_MAX_LEN);
    return off;
}

bool siot_ota_result_decode(const uint8_t *p, size_t len, siot_ota_result_t *r)
{
    if (len < 2 + 2 + 1 || p[0] > 1) return false;
    memset(r, 0, sizeof(*r));
    size_t off = 0;
    r->ok = p[off++] == 1;
    r->reason = p[off++];
    r->awake_s = siot_get_u16(&p[off]); off += 2;
    return get_str(p, len, &off, r->version, SIOT_OTA_VER_MAX_LEN) && off == len;
}

/* ---- OTA_CONTROL ---------------------------------------------------------------------- */

size_t siot_ota_control_encode(uint8_t *p, const siot_ota_control_t *c)
{
    size_t off = 0;
    p[off++] = c->action;
    p[off++] = c->family;
    p[off++] = c->filter;
    switch (c->filter) {
    case SIOT_OTA_FILTER_PRODUCT: siot_put_u16(&p[off], c->product); off += 2; break;
    case SIOT_OTA_FILTER_ZONE:    off += put_str(&p[off], c->zone, SIOT_OTA_ZONE_MAX); break;
    case SIOT_OTA_FILTER_UNIT:    memcpy(&p[off], c->mac, 6); off += 6; break;
    default: break;
    }
    return off;
}

bool siot_ota_control_decode(const uint8_t *p, size_t len, siot_ota_control_t *c)
{
    if (len < 3) return false;
    memset(c, 0, sizeof(*c));
    size_t off = 0;
    c->action = p[off++];
    c->family = p[off++];
    c->filter = p[off++];
    if (c->action < SIOT_OTA_ACT_START || c->action > SIOT_OTA_ACT_ABORT || !family_ok(c->family)) return false;
    switch (c->filter) {
    case SIOT_OTA_FILTER_ALL:
        break;
    case SIOT_OTA_FILTER_PRODUCT:
        if (off + 2 > len) return false;
        c->product = siot_get_u16(&p[off]); off += 2;
        if (c->product == SAFR_PRODUCT_UNKNOWN || (c->product >> 8) != c->family) return false;
        break;
    case SIOT_OTA_FILTER_ZONE:
        if (!get_str(p, len, &off, c->zone, SIOT_OTA_ZONE_MAX) || c->zone[0] == '\0') return false;
        break;
    case SIOT_OTA_FILTER_UNIT:
        if (off + 6 > len) return false;
        memcpy(c->mac, &p[off], 6); off += 6;
        if (siot_mac_is_bcast(c->mac)) return false;
        break;
    default:
        return false;
    }
    return off == len;
}

/* ---- OTA_ROLLOUT ------------------------------------------------------------------------ */

size_t siot_ota_rollout_hdr_encode(uint8_t *p, const siot_ota_rollout_hdr_t *h)
{
    size_t off = 0;
    p[off++] = h->page;
    p[off++] = h->page_count;
    siot_put_u16(&p[off], h->total); off += 2;
    p[off++] = h->count;
    p[off++] = h->state;
    p[off++] = h->family;
    off += put_str(&p[off], h->target, SIOT_OTA_VER_MAX_LEN);
    return off;
}

size_t siot_ota_rollout_hdr_decode(const uint8_t *p, size_t len, siot_ota_rollout_hdr_t *h)
{
    if (len < 7 + 1) return 0;
    memset(h, 0, sizeof(*h));
    size_t off = 0;
    h->page = p[off++];
    h->page_count = p[off++];
    h->total = siot_get_u16(&p[off]); off += 2;
    h->count = p[off++];
    h->state = p[off++];
    h->family = p[off++];
    if (!get_str(p, len, &off, h->target, SIOT_OTA_VER_MAX_LEN)) return 0;
    if (h->page == 0 || h->page > h->page_count || h->state >= SIOT_OTA_RO__COUNT) return 0;
    return off;
}

size_t siot_ota_rollout_entry_len(const siot_ota_rollout_entry_t *e)
{
    return 6 + 2 + 1 + 1 + 1 + 1 + 2 + 1 + strnlen(e->version, SIOT_OTA_VER_MAX_LEN);
}

size_t siot_ota_rollout_entry_encode(uint8_t *p, const siot_ota_rollout_entry_t *e)
{
    size_t off = 0;
    memcpy(&p[off], e->mac, 6); off += 6;
    siot_put_u16(&p[off], e->product); off += 2;
    p[off++] = e->state;
    p[off++] = e->percent > 100 ? 100 : e->percent;
    p[off++] = e->attempts;
    p[off++] = e->reason;
    siot_put_u16(&p[off], e->age_s); off += 2;
    off += put_str(&p[off], e->version, SIOT_OTA_VER_MAX_LEN);
    return off;
}

size_t siot_ota_rollout_entry_decode(const uint8_t *p, size_t len, siot_ota_rollout_entry_t *e)
{
    if (len < 6 + 2 + 4 + 2 + 1) return 0;
    memset(e, 0, sizeof(*e));
    size_t off = 0;
    memcpy(e->mac, &p[off], 6); off += 6;
    e->product = siot_get_u16(&p[off]); off += 2;
    e->state = p[off++];
    e->percent = p[off++];
    e->attempts = p[off++];
    e->reason = p[off++];
    e->age_s = siot_get_u16(&p[off]); off += 2;
    if (!get_str(p, len, &off, e->version, SIOT_OTA_VER_MAX_LEN)) return 0;
    if (e->state >= SIOT_OTA_U__COUNT || e->percent > 100) return 0;
    return off;
}

/* ---- the version rule --------------------------------------------------------------------- */

/* Decimal number without sign or leading garbage; stops at `stop` or the end. */
static bool parse_num(const char **s, uint32_t *out)
{
    const char *p = *s;
    if (*p < '0' || *p > '9') return false;
    uint32_t v = 0;
    int digits = 0;
    while (*p >= '0' && *p <= '9') {
        if (++digits > 9) return false;
        v = v * 10 + (uint32_t)(*p - '0');
        p++;
    }
    *out = v;
    *s = p;
    return true;
}

bool siot_ota_version_parse(const char *s, siot_ota_version_t *out)
{
    if (s == NULL || strnlen(s, SIOT_OTA_VER_MAX_LEN + 1) > SIOT_OTA_VER_MAX_LEN) return false;
    memset(out, 0, sizeof(*out));
    if (!parse_num(&s, &out->major) || *s++ != '.') return false;
    if (!parse_num(&s, &out->minor) || *s++ != '.') return false;
    if (!parse_num(&s, &out->patch)) return false;
    if (*s == '-') {
        s++;
        size_t n = 0;
        while (*s != '\0' && *s != '+') {
            const char c = *s++;
            const bool ok = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
                            c == '.' || c == '-';
            if (!ok) return false;
            out->pre[n++] = c;
        }
        out->pre[n] = '\0';
        if (n == 0) return false;
    }
    return *s == '\0' || *s == '+';
}

int siot_ota_version_cmp(const siot_ota_version_t *a, const siot_ota_version_t *b)
{
    if (a->major != b->major) return a->major < b->major ? -1 : 1;
    if (a->minor != b->minor) return a->minor < b->minor ? -1 : 1;
    if (a->patch != b->patch) return a->patch < b->patch ? -1 : 1;
    const bool a_rel = a->pre[0] == '\0', b_rel = b->pre[0] == '\0';
    if (a_rel != b_rel) return a_rel ? 1 : -1; /* the release is newer than its pre-release */
    const int c = strcmp(a->pre, b->pre);
    return c < 0 ? -1 : c > 0 ? 1 : 0;
}

siot_ota_reason_t siot_ota_accept_version(const char *running, const char *offered, bool force,
                                          bool force_allowed)
{
    siot_ota_version_t run, off;
    if (!siot_ota_version_parse(offered, &off)) return SIOT_OTA_R_BAD_VERSION;
    if (force) return force_allowed ? SIOT_OTA_R_NONE : SIOT_OTA_R_FORCE_REFUSED;
    /* A unit that cannot read its own version must not be left behind for ever. */
    if (!siot_ota_version_parse(running, &run)) return SIOT_OTA_R_NONE;
    return siot_ota_version_cmp(&off, &run) > 0 ? SIOT_OTA_R_NONE : SIOT_OTA_R_NOT_NEWER;
}

/* ---- CRC-32 ---------------------------------------------------------------------------------- */

uint32_t siot_ota_crc32(const uint8_t *data, size_t len)
{
    uint32_t crc = 0xFFFFFFFFu;
    for (size_t i = 0; i < len; i++) {
        crc ^= data[i];
        for (int b = 0; b < 8; b++) crc = (crc >> 1) ^ (0xEDB88320u & (uint32_t)-(int32_t)(crc & 1u));
    }
    return crc ^ 0xFFFFFFFFu;
}
