#include "siot_devtab.h"

#include <stddef.h>
#include <stdio.h>
#include <string.h>

#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "nvs.h"

#include "siot_safr.h"
#include "siot_util.h"

static const char *TAG = "siot_devtab";

/* What goes to NVS (never last_seen / derived state). Fields are only ever
 * appended: a blob written by an older firmware is shorter and loads with the
 * rest zeroed (DEVTAB_REC_V1_LEN = the record before the product fields). */
typedef struct __attribute__((packed)) {
    uint8_t  role;
    uint8_t  stored_state; /* SIOT_DEV_EXPECTED or SIOT_DEV_RETIRED */
    uint8_t  flags;
    uint32_t first_seen;
    char     name[SIOT_NAME_MAX_LEN + 1];
    char     zone[SIOT_ZONE_MAX_LEN + 1];
    /* v2 (protocol v3.5) */
    uint16_t product;
    uint8_t  hw_rev;
    char     fw[SIOT_DEVTAB_FW_MAX_LEN + 1];
} devtab_rec_t;

#define DEVTAB_REC_V1_LEN offsetof(devtab_rec_t, product)
_Static_assert(SIOT_DEVTAB_FW_MAX_LEN == SAFR_FW_MAX_LEN, "devtab fw length follows the wire");

typedef struct {
    bool     used;
    uint8_t  mac[6];
    devtab_rec_t rec;
    int64_t  last_seen_ms; /* <0 = never this boot */
} slot_t;

static slot_t s_tab[SIOT_DEVTAB_CAP];
static size_t s_count;
static SemaphoreHandle_t s_lock;

static void key_for(const uint8_t mac[6], char out[13])
{
    static const char hex[] = "0123456789abcdef";
    for (int i = 0; i < 6; i++) {
        out[i * 2] = hex[mac[i] >> 4];
        out[i * 2 + 1] = hex[mac[i] & 0x0F];
    }
    out[12] = '\0';
}

static slot_t *find(const uint8_t mac[6])
{
    for (size_t i = 0; i < SIOT_DEVTAB_CAP; i++) {
        if (s_tab[i].used && siot_mac_eq(s_tab[i].mac, mac)) return &s_tab[i];
    }
    return NULL;
}

static slot_t *alloc(const uint8_t mac[6])
{
    for (size_t i = 0; i < SIOT_DEVTAB_CAP; i++) {
        if (s_tab[i].used) continue;
        memset(&s_tab[i], 0, sizeof(s_tab[i]));
        s_tab[i].used = true;
        memcpy(s_tab[i].mac, mac, 6);
        s_tab[i].rec.role = SIOT_DEV_ROLE_UNKNOWN;
        s_tab[i].rec.stored_state = SIOT_DEV_EXPECTED;
        s_tab[i].last_seen_ms = -1;
        s_count++;
        return &s_tab[i];
    }
    return NULL;
}

static esp_err_t persist(const slot_t *s)
{
    nvs_handle_t h;
    esp_err_t err = nvs_open(SIOT_DEVTAB_NS, NVS_READWRITE, &h);
    if (err != ESP_OK) return err;
    char key[13];
    key_for(s->mac, key);
    err = nvs_set_blob(h, key, &s->rec, sizeof(s->rec));
    if (err == ESP_OK) err = nvs_commit(h);
    nvs_close(h);
    if (err != ESP_OK) ESP_LOGW(TAG, "persist %s: %s", key, esp_err_to_name(err));
    return err;
}

static esp_err_t unpersist(const uint8_t mac[6])
{
    nvs_handle_t h;
    esp_err_t err = nvs_open(SIOT_DEVTAB_NS, NVS_READWRITE, &h);
    if (err != ESP_OK) return err;
    char key[13];
    key_for(mac, key);
    err = nvs_erase_key(h, key);
    if (err == ESP_OK) err = nvs_commit(h);
    nvs_close(h);
    return err;
}

static bool mac_from_key(const char *key, uint8_t mac[6])
{
    if (strlen(key) != 12) return false;
    return siot_hex_decode(key, mac, 6) == 6;
}

esp_err_t siot_devtab_init(void)
{
    if (s_lock == NULL) s_lock = xSemaphoreCreateMutex();
    if (s_lock == NULL) return ESP_ERR_NO_MEM;
    memset(s_tab, 0, sizeof(s_tab));
    s_count = 0;

    nvs_handle_t h;
    esp_err_t err = nvs_open(SIOT_DEVTAB_NS, NVS_READONLY, &h);
    if (err == ESP_ERR_NVS_NOT_FOUND) {
        ESP_LOGI(TAG, "empty table");
        return ESP_OK;
    }
    if (err != ESP_OK) return err;

    nvs_iterator_t it = NULL;
    err = nvs_entry_find_in_handle(h, NVS_TYPE_BLOB, &it);
    while (err == ESP_OK) {
        nvs_entry_info_t info;
        nvs_entry_info(it, &info);
        uint8_t mac[6];
        devtab_rec_t rec;
        memset(&rec, 0, sizeof(rec));
        size_t len = sizeof(rec);
        if (mac_from_key(info.key, mac) &&
            nvs_get_blob(h, info.key, &rec, &len) == ESP_OK &&
            (len == sizeof(rec) || len == DEVTAB_REC_V1_LEN)) { /* V1: rewritten at its next change */
            slot_t *s = alloc(mac);
            if (s == NULL) {
                ESP_LOGW(TAG, "table full while loading (%s dropped)", info.key);
            } else {
                s->rec = rec;
                s->rec.name[SIOT_NAME_MAX_LEN] = '\0';
                s->rec.zone[SIOT_ZONE_MAX_LEN] = '\0';
                s->rec.fw[SIOT_DEVTAB_FW_MAX_LEN] = '\0';
            }
        }
        err = nvs_entry_next(&it);
    }
    nvs_release_iterator(it);
    nvs_close(h);
    ESP_LOGI(TAG, "loaded %u device(s), cap %d", (unsigned)s_count, SIOT_DEVTAB_CAP);
    return ESP_OK;
}

size_t siot_devtab_count(void)
{
    xSemaphoreTake(s_lock, portMAX_DELAY);
    const size_t n = s_count;
    xSemaphoreGive(s_lock);
    return n;
}

static uint8_t derive_state(const slot_t *s, int64_t now_ms)
{
    if (s->rec.stored_state == SIOT_DEV_RETIRED) return SIOT_DEV_RETIRED;
    if (s->last_seen_ms < 0) {
        /* Never heard this boot: still `expected` if never heard at all,
         * `missing` if it was online before the board rebooted. */
        return (s->rec.flags & SIOT_DEV_F_SEEN_EVER) ? SIOT_DEV_MISSING : SIOT_DEV_EXPECTED;
    }
    const int64_t timeout = s->rec.role == SAFR_ROLE_LEAF ? SIOT_DEVTAB_LEAF_TIMEOUT_MS
                                                          : SIOT_DEVTAB_AC_TIMEOUT_MS;
    return (now_ms - s->last_seen_ms) > timeout ? SIOT_DEV_MISSING : SIOT_DEV_ONLINE;
}

static void fill(const slot_t *s, int64_t now_ms, siot_devtab_entry_t *out)
{
    memcpy(out->mac, s->mac, 6);
    out->role = s->rec.role;
    out->state = derive_state(s, now_ms);
    out->flags = s->rec.flags;
    out->first_seen = s->rec.first_seen;
    out->last_seen_ms = s->last_seen_ms;
    memcpy(out->name, s->rec.name, sizeof(out->name));
    memcpy(out->zone, s->rec.zone, sizeof(out->zone));
    out->product = s->rec.product;
    out->hw_rev = s->rec.hw_rev;
    memcpy(out->fw, s->rec.fw, sizeof(out->fw));
}

bool siot_devtab_get(const uint8_t mac[6], int64_t now_ms, siot_devtab_entry_t *out)
{
    xSemaphoreTake(s_lock, portMAX_DELAY);
    const slot_t *s = find(mac);
    if (s) fill(s, now_ms, out);
    xSemaphoreGive(s_lock);
    return s != NULL;
}

esp_err_t siot_devtab_mark_missing(const uint8_t mac[6], int64_t now_ms)
{
    xSemaphoreTake(s_lock, portMAX_DELAY);
    slot_t *s = find(mac);
    if (s == NULL) { xSemaphoreGive(s_lock); return ESP_ERR_NOT_FOUND; }
    /* Older than the longest timeout, whatever the role. */
    s->last_seen_ms = now_ms - SIOT_DEVTAB_LEAF_TIMEOUT_MS - 1;
    xSemaphoreGive(s_lock);
    return ESP_OK;
}

bool siot_devtab_touch(const uint8_t mac[6], int64_t now_ms, uint32_t epoch_now,
                       uint8_t role, uint8_t *flags_out)
{
    bool retired = false;
    xSemaphoreTake(s_lock, portMAX_DELAY);
    slot_t *s = find(mac);
    bool dirty = false;
    if (s == NULL) {
        s = alloc(mac);
        if (s == NULL) {
            xSemaphoreGive(s_lock);
            ESP_LOGW(TAG, "table full: unit not tracked");
            if (flags_out) *flags_out = 0;
            return false;
        }
        dirty = true;
    }
    if (s->rec.stored_state == SIOT_DEV_RETIRED) {
        retired = true;
        if (!(s->rec.flags & SIOT_DEV_F_HEARD_WHILE_RETIRED)) {
            s->rec.flags |= SIOT_DEV_F_HEARD_WHILE_RETIRED;
            dirty = true;
        }
    }
    if (!(s->rec.flags & SIOT_DEV_F_SEEN_EVER)) {
        s->rec.flags |= SIOT_DEV_F_SEEN_EVER;
        s->rec.first_seen = epoch_now;
        dirty = true;
    }
    if (role != SIOT_DEV_ROLE_UNKNOWN && s->rec.role != role) {
        s->rec.role = role;
        dirty = true;
    }
    s->last_seen_ms = now_ms;
    if (flags_out) *flags_out = s->rec.flags;
    if (dirty) persist(s);
    xSemaphoreGive(s_lock);
    return retired;
}

esp_err_t siot_devtab_set_product(const uint8_t mac[6], uint16_t product, uint8_t hw_rev, const char *fw)
{
    xSemaphoreTake(s_lock, portMAX_DELAY);
    slot_t *s = find(mac);
    if (s == NULL) { xSemaphoreGive(s_lock); return ESP_ERR_NOT_FOUND; }
    bool dirty = false;
    if (product != 0 && (s->rec.product != product || s->rec.hw_rev != hw_rev)) {
        s->rec.product = product;
        s->rec.hw_rev = hw_rev;
        dirty = true;
    }
    if (fw != NULL && fw[0] != '\0' && strncmp(s->rec.fw, fw, SIOT_DEVTAB_FW_MAX_LEN) != 0) {
        strlcpy(s->rec.fw, fw, sizeof(s->rec.fw));
        dirty = true;
    }
    const esp_err_t err = dirty ? persist(s) : ESP_OK;
    xSemaphoreGive(s_lock);
    return err;
}

static void copy_name_zone(devtab_rec_t *rec, const char *name, const char *zone)
{
    if (name) strlcpy(rec->name, name, sizeof(rec->name));
    if (zone) strlcpy(rec->zone, zone, sizeof(rec->zone));
}

esp_err_t siot_devtab_announce(const uint8_t mac[6], const char *name, const char *zone, uint8_t role)
{
    xSemaphoreTake(s_lock, portMAX_DELAY);
    slot_t *s = find(mac);
    if (s == NULL) s = alloc(mac);
    if (s == NULL) { xSemaphoreGive(s_lock); return ESP_ERR_NO_MEM; }
    bool dirty = false;
    if (role != SIOT_DEV_ROLE_UNKNOWN && s->rec.role != role) { s->rec.role = role; dirty = true; }
    const bool matches_pending = (s->rec.flags & SIOT_DEV_F_PENDING_RENAME) &&
                                 strcmp(s->rec.name, name ? name : "") == 0 &&
                                 strcmp(s->rec.zone, zone ? zone : "") == 0;
    if (matches_pending) {
        s->rec.flags &= (uint8_t)~SIOT_DEV_F_PENDING_RENAME;
        dirty = true;
    } else if (!(s->rec.flags & SIOT_DEV_F_ANNOTATED)) {
        if (strcmp(s->rec.name, name ? name : "") != 0 || strcmp(s->rec.zone, zone ? zone : "") != 0) {
            copy_name_zone(&s->rec, name, zone);
            dirty = true;
        }
    }
    if (dirty) persist(s);
    xSemaphoreGive(s_lock);
    return ESP_OK;
}

esp_err_t siot_devtab_hint(const uint8_t mac[6], const char *name, const char *zone)
{
    xSemaphoreTake(s_lock, portMAX_DELAY);
    if (find(mac) != NULL) { xSemaphoreGive(s_lock); return ESP_OK; }
    slot_t *s = alloc(mac);
    if (s == NULL) { xSemaphoreGive(s_lock); return ESP_ERR_NO_MEM; }
    copy_name_zone(&s->rec, name, zone);
    const esp_err_t err = persist(s);
    xSemaphoreGive(s_lock);
    return err;
}

esp_err_t siot_devtab_set_name_zone(const uint8_t mac[6], const char *name, const char *zone,
                                    bool online_now)
{
    xSemaphoreTake(s_lock, portMAX_DELAY);
    slot_t *s = find(mac);
    if (s == NULL) s = alloc(mac);
    if (s == NULL) { xSemaphoreGive(s_lock); return ESP_ERR_NO_MEM; }
    copy_name_zone(&s->rec, name, zone);
    s->rec.flags |= SIOT_DEV_F_ANNOTATED;
    if (online_now) s->rec.flags &= (uint8_t)~SIOT_DEV_F_PENDING_RENAME;
    else s->rec.flags |= SIOT_DEV_F_PENDING_RENAME;
    const esp_err_t err = persist(s);
    xSemaphoreGive(s_lock);
    return err;
}

esp_err_t siot_devtab_retire(const uint8_t mac[6], bool pending_decommission)
{
    xSemaphoreTake(s_lock, portMAX_DELAY);
    slot_t *s = find(mac);
    if (s == NULL) { xSemaphoreGive(s_lock); return ESP_ERR_NOT_FOUND; }
    s->rec.stored_state = SIOT_DEV_RETIRED;
    s->rec.flags &= (uint8_t)~(SIOT_DEV_F_HEARD_WHILE_RETIRED | SIOT_DEV_F_PENDING_RENAME);
    if (pending_decommission) s->rec.flags |= SIOT_DEV_F_PENDING_DECOMMISSION;
    const esp_err_t err = persist(s);
    xSemaphoreGive(s_lock);
    return err;
}

esp_err_t siot_devtab_unretire(const uint8_t mac[6])
{
    xSemaphoreTake(s_lock, portMAX_DELAY);
    slot_t *s = find(mac);
    if (s == NULL) { xSemaphoreGive(s_lock); return ESP_ERR_NOT_FOUND; }
    if (s->rec.stored_state != SIOT_DEV_RETIRED) { xSemaphoreGive(s_lock); return ESP_ERR_INVALID_STATE; }
    s->rec.stored_state = SIOT_DEV_EXPECTED;
    s->rec.flags &= (uint8_t)~(SIOT_DEV_F_HEARD_WHILE_RETIRED | SIOT_DEV_F_PENDING_DECOMMISSION);
    const esp_err_t err = persist(s);
    xSemaphoreGive(s_lock);
    return err;
}

esp_err_t siot_devtab_forget(const uint8_t mac[6])
{
    xSemaphoreTake(s_lock, portMAX_DELAY);
    slot_t *s = find(mac);
    if (s == NULL) { xSemaphoreGive(s_lock); return ESP_ERR_NOT_FOUND; }
    if (s->rec.stored_state != SIOT_DEV_RETIRED) { xSemaphoreGive(s_lock); return ESP_ERR_INVALID_STATE; }
    s->used = false;
    s_count--;
    const esp_err_t err = unpersist(mac);
    xSemaphoreGive(s_lock);
    return err;
}

esp_err_t siot_devtab_replace(const uint8_t old_mac[6], const uint8_t new_mac[6], int64_t now_ms,
                              bool *old_online_out)
{
    xSemaphoreTake(s_lock, portMAX_DELAY);
    slot_t *o = find(old_mac);
    if (o == NULL) { xSemaphoreGive(s_lock); return ESP_ERR_NOT_FOUND; }
    slot_t *n = find(new_mac);
    if (n == NULL) n = alloc(new_mac);
    if (n == NULL) { xSemaphoreGive(s_lock); return ESP_ERR_NO_MEM; }
    const bool old_online = derive_state(o, now_ms) == SIOT_DEV_ONLINE;

    copy_name_zone(&n->rec, o->rec.name, o->rec.zone);
    n->rec.flags |= SIOT_DEV_F_ANNOTATED | SIOT_DEV_F_PENDING_RENAME;
    if (derive_state(n, now_ms) == SIOT_DEV_ONLINE) {
        /* Heard recently: push the rename right away (coordinator does it). */
    }
    o->rec.stored_state = SIOT_DEV_RETIRED;
    o->rec.flags &= (uint8_t)~(SIOT_DEV_F_HEARD_WHILE_RETIRED | SIOT_DEV_F_PENDING_RENAME);
    if (old_online) o->rec.flags |= SIOT_DEV_F_PENDING_DECOMMISSION;
    esp_err_t err = persist(n);
    if (err == ESP_OK) err = persist(o);
    if (old_online_out) *old_online_out = old_online;
    xSemaphoreGive(s_lock);
    return err;
}

esp_err_t siot_devtab_clear_flags(const uint8_t mac[6], uint8_t flags)
{
    xSemaphoreTake(s_lock, portMAX_DELAY);
    slot_t *s = find(mac);
    if (s == NULL) { xSemaphoreGive(s_lock); return ESP_ERR_NOT_FOUND; }
    esp_err_t err = ESP_OK;
    if (s->rec.flags & flags) {
        s->rec.flags &= (uint8_t)~flags;
        err = persist(s);
    }
    xSemaphoreGive(s_lock);
    return err;
}

size_t siot_devtab_snapshot(siot_devtab_entry_t *out, size_t max, int64_t now_ms)
{
    size_t n = 0;
    xSemaphoreTake(s_lock, portMAX_DELAY);
    for (size_t i = 0; i < SIOT_DEVTAB_CAP && n < max; i++) {
        if (!s_tab[i].used) continue;
        fill(&s_tab[i], now_ms, &out[n++]);
    }
    xSemaphoreGive(s_lock);
    return n;
}

esp_err_t siot_devtab_erase_all(void)
{
    nvs_handle_t h;
    esp_err_t err = nvs_open(SIOT_DEVTAB_NS, NVS_READWRITE, &h);
    if (err == ESP_ERR_NVS_NOT_FOUND) return ESP_OK;
    if (err != ESP_OK) return err;
    err = nvs_erase_all(h);
    if (err == ESP_OK) err = nvs_commit(h);
    nvs_close(h);
    if (s_lock) {
        xSemaphoreTake(s_lock, portMAX_DELAY);
        memset(s_tab, 0, sizeof(s_tab));
        s_count = 0;
        xSemaphoreGive(s_lock);
    }
    return err;
}
