#include "siot_labels.h"

#include <string.h>

#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "nvs.h"

static const char *TAG = "siot_labels";

#define LABELS_BLOB_VER 1
/* VER ‖ REV ‖ COUNT ‖ CAP × (ID ‖ NAME_LEN ‖ NAME) */
#define LABELS_BLOB_MAX (1 + 2 + 1 + SAFR_LABEL_CAP * (2 + 1 + SAFR_LABEL_NAME_MAX))

typedef struct {
    siot_safr_label_t items[SAFR_LABEL_CAP];
    size_t   count;
    uint16_t rev;
} table_t;

static table_t s_zone, s_addr;
static SemaphoreHandle_t s_lock;

static table_t *table_for(uint8_t kind)
{
    if (kind == SAFR_LABEL_ZONE) return &s_zone;
    if (kind == SAFR_LABEL_ADDRESS) return &s_addr;
    return NULL;
}

static const char *key_for(uint8_t kind)
{
    return kind == SAFR_LABEL_ZONE ? "zone" : "addr";
}

static int find(const table_t *t, uint16_t id)
{
    for (size_t i = 0; i < t->count; i++) {
        if (t->items[i].id == id) return (int)i;
    }
    return -1;
}

static esp_err_t persist(uint8_t kind, const table_t *t)
{
    uint8_t blob[LABELS_BLOB_MAX];
    size_t off = 0;
    blob[off++] = LABELS_BLOB_VER;
    blob[off++] = (uint8_t)(t->rev >> 8);
    blob[off++] = (uint8_t)(t->rev & 0xFF);
    blob[off++] = (uint8_t)t->count;
    for (size_t i = 0; i < t->count; i++) {
        const size_t len = strnlen(t->items[i].name, SAFR_LABEL_NAME_MAX);
        blob[off++] = (uint8_t)(t->items[i].id >> 8);
        blob[off++] = (uint8_t)(t->items[i].id & 0xFF);
        blob[off++] = (uint8_t)len;
        memcpy(&blob[off], t->items[i].name, len);
        off += len;
    }
    nvs_handle_t h;
    esp_err_t err = nvs_open(SIOT_LABELS_NS, NVS_READWRITE, &h);
    if (err != ESP_OK) return err;
    err = nvs_set_blob(h, key_for(kind), blob, off);
    if (err == ESP_OK) err = nvs_commit(h);
    nvs_close(h);
    if (err != ESP_OK) ESP_LOGW(TAG, "persist %s: %s", key_for(kind), esp_err_to_name(err));
    return err;
}

/* Parses one stored blob into `t`; false (table left empty) on any defect. */
static bool load_blob(const uint8_t *blob, size_t len, table_t *t)
{
    memset(t, 0, sizeof(*t));
    if (len < 4 || blob[0] != LABELS_BLOB_VER) return false;
    const uint16_t rev = (uint16_t)(((uint16_t)blob[1] << 8) | blob[2]);
    const size_t count = blob[3];
    if (count > SAFR_LABEL_CAP) return false;
    size_t off = 4;
    for (size_t i = 0; i < count; i++) {
        if (off + 3 > len) return false;
        const uint16_t id = (uint16_t)(((uint16_t)blob[off] << 8) | blob[off + 1]);
        const size_t nlen = blob[off + 2];
        off += 3;
        if (id == SAFR_LABEL_ID_NONE || nlen == 0 || nlen > SAFR_LABEL_NAME_MAX || off + nlen > len) return false;
        t->items[i].id = id;
        memcpy(t->items[i].name, &blob[off], nlen);
        t->items[i].name[nlen] = '\0';
        off += nlen;
    }
    if (off != len) return false;
    t->count = count;
    t->rev = rev;
    return true;
}

static void load_kind(nvs_handle_t h, uint8_t kind, table_t *t)
{
    uint8_t blob[LABELS_BLOB_MAX];
    size_t len = sizeof(blob);
    memset(t, 0, sizeof(*t));
    const esp_err_t err = nvs_get_blob(h, key_for(kind), blob, &len);
    if (err == ESP_ERR_NVS_NOT_FOUND) return;
    if (err != ESP_OK || !load_blob(blob, len, t)) {
        ESP_LOGW(TAG, "%s table unreadable (%s): dropped, the tablet restores it",
                 key_for(kind), esp_err_to_name(err));
        memset(t, 0, sizeof(*t));
    }
}

esp_err_t siot_labels_init(void)
{
    if (s_lock == NULL) s_lock = xSemaphoreCreateMutex();
    if (s_lock == NULL) return ESP_ERR_NO_MEM;
    memset(&s_zone, 0, sizeof(s_zone));
    memset(&s_addr, 0, sizeof(s_addr));
    nvs_handle_t h;
    esp_err_t err = nvs_open(SIOT_LABELS_NS, NVS_READONLY, &h);
    if (err == ESP_ERR_NVS_NOT_FOUND) {
        ESP_LOGI(TAG, "no labels");
        return ESP_OK;
    }
    if (err != ESP_OK) return err;
    load_kind(h, SAFR_LABEL_ZONE, &s_zone);
    load_kind(h, SAFR_LABEL_ADDRESS, &s_addr);
    nvs_close(h);
    ESP_LOGI(TAG, "loaded %u zone(s) rev %u, %u address(es) rev %u", (unsigned)s_zone.count, s_zone.rev,
             (unsigned)s_addr.count, s_addr.rev);
    return ESP_OK;
}

esp_err_t siot_labels_set(uint8_t kind, uint16_t id, const char *name)
{
    table_t *t = table_for(kind);
    const size_t len = name ? strnlen(name, SAFR_LABEL_NAME_MAX + 1) : 0;
    if (t == NULL || id == SAFR_LABEL_ID_NONE || len == 0 || len > SAFR_LABEL_NAME_MAX) return ESP_ERR_INVALID_ARG;
    xSemaphoreTake(s_lock, portMAX_DELAY);
    int i = find(t, id);
    if (i >= 0 && strcmp(t->items[i].name, name) == 0) { xSemaphoreGive(s_lock); return ESP_OK; }
    if (i < 0) {
        if (t->count >= SAFR_LABEL_CAP) { xSemaphoreGive(s_lock); return ESP_ERR_NO_MEM; }
        /* keep id order so pages are stable */
        i = (int)t->count;
        while (i > 0 && t->items[i - 1].id > id) { t->items[i] = t->items[i - 1]; i--; }
        t->items[i].id = id;
        t->count++;
    }
    strlcpy(t->items[i].name, name, sizeof(t->items[i].name));
    t->rev++;
    const esp_err_t err = persist(kind, t);
    xSemaphoreGive(s_lock);
    return err;
}

esp_err_t siot_labels_del(uint8_t kind, uint16_t id)
{
    table_t *t = table_for(kind);
    if (t == NULL || id == SAFR_LABEL_ID_NONE) return ESP_ERR_INVALID_ARG;
    xSemaphoreTake(s_lock, portMAX_DELAY);
    const int i = find(t, id);
    if (i < 0) { xSemaphoreGive(s_lock); return ESP_ERR_NOT_FOUND; }
    for (size_t j = (size_t)i + 1; j < t->count; j++) t->items[j - 1] = t->items[j];
    t->count--;
    memset(&t->items[t->count], 0, sizeof(t->items[0]));
    t->rev++;
    const esp_err_t err = persist(kind, t);
    xSemaphoreGive(s_lock);
    return err;
}

bool siot_labels_exists(uint8_t kind, uint16_t id)
{
    if (id == SAFR_LABEL_ID_NONE) return true;
    const table_t *t = table_for(kind);
    if (t == NULL) return false;
    xSemaphoreTake(s_lock, portMAX_DELAY);
    const bool found = find(t, id) >= 0;
    xSemaphoreGive(s_lock);
    return found;
}

uint16_t siot_labels_find(uint8_t kind, const char *name)
{
    const table_t *t = table_for(kind);
    if (t == NULL || name == NULL || name[0] == '\0') return SAFR_LABEL_ID_NONE;
    uint16_t id = SAFR_LABEL_ID_NONE;
    xSemaphoreTake(s_lock, portMAX_DELAY);
    for (size_t i = 0; i < t->count; i++) {
        if (strcmp(t->items[i].name, name) == 0) { id = t->items[i].id; break; }
    }
    xSemaphoreGive(s_lock);
    return id;
}

uint16_t siot_labels_next_id(uint8_t kind)
{
    const table_t *t = table_for(kind);
    if (t == NULL) return 1;
    xSemaphoreTake(s_lock, portMAX_DELAY);
    /* id order is kept on insert: the last item has the highest id */
    const uint16_t next = t->count ? (uint16_t)(t->items[t->count - 1].id + 1) : 1;
    xSemaphoreGive(s_lock);
    return next ? next : 1;
}

size_t siot_labels_snapshot(uint8_t kind, siot_safr_label_t *out, size_t max, uint16_t *rev_out)
{
    const table_t *t = table_for(kind);
    if (t == NULL) { if (rev_out) *rev_out = 0; return 0; }
    xSemaphoreTake(s_lock, portMAX_DELAY);
    const size_t n = t->count < max ? t->count : max;
    memcpy(out, t->items, n * sizeof(out[0]));
    if (rev_out) *rev_out = t->rev;
    xSemaphoreGive(s_lock);
    return n;
}

esp_err_t siot_labels_erase_all(void)
{
    nvs_handle_t h;
    esp_err_t err = nvs_open(SIOT_LABELS_NS, NVS_READWRITE, &h);
    if (err == ESP_ERR_NVS_NOT_FOUND) return ESP_OK;
    if (err != ESP_OK) return err;
    err = nvs_erase_all(h);
    if (err == ESP_OK) err = nvs_commit(h);
    nvs_close(h);
    if (s_lock) {
        xSemaphoreTake(s_lock, portMAX_DELAY);
        memset(&s_zone, 0, sizeof(s_zone));
        memset(&s_addr, 0, sizeof(s_addr));
        xSemaphoreGive(s_lock);
    }
    return err;
}
