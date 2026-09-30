/* siot_ota_board — protocol §13.3. Layout of this file:
 *   1. state            4. OTA_PUSH_BEGIN / CHUNK / END
 *   2. fw_store         5. OTA_BAUD, the sink
 *   3. targets (slot / file)   6. self-test, rollback report, the 1 s task
 * The push handlers run in the serial link's rx task; the 1 s task owns the
 * timeouts. s_lock guards s_push between them. */
#include "siot_ota_board.h"

#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "esp_app_desc.h"
#include "esp_app_format.h"
#include "esp_log.h"
#include "esp_ota_ops.h"
#include "esp_partition.h"
#include "esp_secure_boot.h"
#include "esp_system.h"
#include "esp_timer.h"
#include "esp_vfs_fat.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "freertos/task.h"
#include "mbedtls/sha256.h"
#include "nvs.h"
#include "sdkconfig.h"
#include "wear_levelling.h"

#include "ota_internal.h"
#include "siot_config.h"
#include "siot_coordinator.h"
#include "siot_evbus.h"
#include "siot_identity.h"
#include "siot_link.h"
#include "siot_ota_proto.h"
#include "siot_safr.h"
#include "siot_util.h"
#include "siot_version.h"

static const char *TAG = "siot_ota";

#define FW_MOUNT          OTA_FW_MOUNT
#define FW_PARTITION      "fw_store"
#define SIG_SECTOR        4096                /* sizeof(ets_secure_boot_signature_t) */
#define APP_DESC_OFFSET   (sizeof(esp_image_header_t) + sizeof(esp_image_segment_header_t)) /* 32 */
#define MIN_CHUNK         512                 /* the first chunk must hold the app description */
#define STALL_MS          120000              /* a push nobody continues is dropped */
#define REBOOT_DELAY_MS   1500                /* OTA_PUSH_RESULT must reach the tablet first */
#define NVS_NS            "siot_ota"
#define NVS_KEY_REPORTED  "rb_reported"

#if CONFIG_SIOT_OTA_ALLOW_FORCE
#define FORCE_ALLOWED true
#else
#define FORCE_ALLOWED false
#endif

/* TEST ONLY (docs/ota/before-production.md item 1): the "newer version only"
 * rule of protocol §13.2 is off, the same image can be pushed again. */
#if CONFIG_SIOT_OTA_TEST_ANY_VERSION
#define ANY_VERSION true
#else
#define ANY_VERSION false
#endif

/* ---- 1. state ------------------------------------------------------------------ */

typedef struct {
    bool     active;
    siot_ota_image_t img;
    uint32_t next_seq;
    uint32_t received;                 /* bytes written */
    mbedtls_sha256_context sha_all;    /* the whole file: SHA256 of OTA_PUSH_BEGIN */
    mbedtls_sha256_context sha_signed; /* all but the signature sector: what the signature covers */
    uint8_t *buf;                      /* the chunk being received, img.chunk bytes */
    uint8_t *sig;                      /* the last SIG_SECTOR bytes of the file */
    /* the chunk whose raw bytes are arriving */
    siot_ota_chunk_t cur;
    uint16_t cur_msg_id;
    bool     cur_store;                /* false: a repeat or a stray — read and drop */
    size_t   cur_fill;
    /* target */
    const esp_partition_t *part;       /* board image */
    esp_ota_handle_t ota;
    bool     ota_open;
    FILE    *fp;                       /* node / leaf image */
    int64_t  last_ms;
    bool     verify;                   /* OTA_PUSH_END heard: the 1 s task gives the verdict */
} push_t;

static push_t s_push;
static SemaphoreHandle_t s_lock;
static bool s_store_ok;                /* fw_store mounted */
static uint8_t s_stored_family;        /* a push was just stored: the rollout must hear of it */
static wl_handle_t s_wl = WL_INVALID_HANDLE;
static int64_t s_reboot_at_ms;         /* 0 = no reboot pending */
static bool s_selftest;                /* this boot is the first of a new image */
static int64_t s_selftest_deadline_ms;
static bool s_rollback_pending;        /* an image was rolled back: the tablet does not know yet */
static char s_rollback_version[SIOT_OTA_VER_MAX_LEN + 1];
static uint8_t s_rollback_id[8];

static int64_t now_ms(void) { return esp_timer_get_time() / 1000; }

const char *ota_family_name(uint8_t family);
bool ota_store_ok(void) { return s_store_ok; }
void ota_path_for(uint8_t family, const char *ext, char out[24])
{
    snprintf(out, 24, FW_MOUNT "/%s.%s", ota_family_name(family), ext); /* 8.3 names: no LFN needed */
}

const char *ota_family_name(uint8_t family)
{
    switch (family) {
    case SAFR_FAMILY_BOARD: return "board";
    case SAFR_FAMILY_NODE:  return "node";
    case SAFR_FAMILY_LEAF:  return "leaf";
    default:                return "?";
    }
}

#define family_name ota_family_name
#define path_for    ota_path_for

static void send_result(uint8_t phase, uint8_t reason, uint8_t family, uint32_t next_seq, const char *version)
{
    siot_ota_push_result_t r = {.phase = phase, .reason = reason, .family = family, .next_seq = next_seq};
    strlcpy(r.version, version ? version : "", sizeof(r.version));
    uint8_t p[SAFR_MAX_PAYLOAD];
    siot_coordinator_send_to_tablet(SAFR_MSG_OTA_PUSH_RESULT, 0, p, siot_ota_push_result_encode(p, &r));
}

/* ---- 2. fw_store ------------------------------------------------------------------ */

static void store_mount(void)
{
    if (esp_partition_find_first(ESP_PARTITION_TYPE_DATA, ESP_PARTITION_SUBTYPE_DATA_FAT, FW_PARTITION) == NULL) {
        ESP_LOGW(TAG, "no %s partition (4 MB table): this board can update itself, "
                      "it cannot hold a node or leaf image", FW_PARTITION);
        return;
    }
    const esp_vfs_fat_mount_config_t cfg = {
        .format_if_mount_failed = true,
        .max_files = 4,
        .allocation_unit_size = 4096,
    };
    const esp_err_t err = esp_vfs_fat_spiflash_mount_rw_wl(FW_MOUNT, FW_PARTITION, &cfg, &s_wl);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "%s: %s", FW_PARTITION, esp_err_to_name(err));
        return;
    }
    s_store_ok = true;
    uint64_t total = 0, free_b = 0;
    esp_vfs_fat_info(FW_MOUNT, &total, &free_b);
    ESP_LOGI(TAG, "%s mounted: %llu KB, %llu KB free", FW_PARTITION, total / 1024, free_b / 1024);
    for (uint8_t f = SAFR_FAMILY_NODE; f <= SAFR_FAMILY_LEAF; f++) {
        char v[SIOT_OTA_VER_MAX_LEN + 1];
        uint32_t size;
        uint8_t sha[SIOT_OTA_SHA_LEN];
        if (siot_ota_board_stored(f, v, &size, sha)) {
            ESP_LOGI(TAG, "stored: %s %s, %lu B", family_name(f), v, (unsigned long)size);
        }
    }
}

/* <family>.inf: VER_LEN ‖ VERSION ‖ SIZE u32 ‖ SHA256[32] — written after the
 * image file is complete and verified, so an .inf means a good .bin. */
static bool store_info_write(const siot_ota_image_t *img)
{
    char path[24];
    path_for(img->family, "inf", path);
    uint8_t p[1 + SIOT_OTA_VER_MAX_LEN + 4 + SIOT_OTA_SHA_LEN];
    size_t off = 0;
    const size_t n = strnlen(img->version, SIOT_OTA_VER_MAX_LEN);
    p[off++] = (uint8_t)n;
    memcpy(&p[off], img->version, n); off += n;
    siot_put_u32(&p[off], img->size); off += 4;
    memcpy(&p[off], img->sha256, SIOT_OTA_SHA_LEN); off += SIOT_OTA_SHA_LEN;
    FILE *f = fopen(path, "wb");
    if (f == NULL) return false;
    const bool ok = fwrite(p, 1, off, f) == off;
    return fclose(f) == 0 && ok;
}

bool siot_ota_board_stored(uint8_t family, char *version, uint32_t *size, uint8_t *sha256)
{
    if (!s_store_ok || (family != SAFR_FAMILY_NODE && family != SAFR_FAMILY_LEAF)) return false;
    char path[24];
    path_for(family, "inf", path);
    FILE *f = fopen(path, "rb");
    if (f == NULL) return false;
    uint8_t p[1 + SIOT_OTA_VER_MAX_LEN + 4 + SIOT_OTA_SHA_LEN];
    const size_t got = fread(p, 1, sizeof(p), f);
    fclose(f);
    if (got < 1 || p[0] == 0 || p[0] > SIOT_OTA_VER_MAX_LEN || got != (size_t)1 + p[0] + 4 + SIOT_OTA_SHA_LEN) return false;
    const uint32_t sz = siot_get_u32(&p[1 + p[0]]);
    struct stat st;
    path_for(family, "bin", path);
    if (stat(path, &st) != 0 || (uint32_t)st.st_size != sz) return false; /* the image it describes is gone */
    if (version) { memcpy(version, &p[1], p[0]); version[p[0]] = '\0'; }
    if (size) *size = sz;
    if (sha256) memcpy(sha256, &p[1 + p[0] + 4], SIOT_OTA_SHA_LEN);
    return true;
}

/* ---- 3. targets ------------------------------------------------------------------- */

static void push_drop(const char *why)
{
    if (!s_push.active) return;
    ESP_LOGW(TAG, "push of %s %s dropped at %lu / %lu B: %s", family_name(s_push.img.family), s_push.img.version,
             (unsigned long)s_push.received, (unsigned long)s_push.img.size, why);
    if (s_push.ota_open) esp_ota_abort(s_push.ota);
    if (s_push.fp) {
        fclose(s_push.fp);
        char path[24];
        path_for(s_push.img.family, "tmp", path);
        unlink(path);
    }
    mbedtls_sha256_free(&s_push.sha_all);
    mbedtls_sha256_free(&s_push.sha_signed);
    free(s_push.buf);
    free(s_push.sig);
    memset(&s_push, 0, sizeof(s_push));
}

static siot_ota_reason_t target_open(void)
{
    const siot_ota_image_t *img = &s_push.img;
    if (img->family == SAFR_FAMILY_BOARD) {
        s_push.part = esp_ota_get_next_update_partition(NULL);
        if (s_push.part == NULL || img->size > s_push.part->size) return SIOT_OTA_R_NO_SPACE;
        if (esp_ota_begin(s_push.part, OTA_WITH_SEQUENTIAL_WRITES, &s_push.ota) != ESP_OK) return SIOT_OTA_R_NO_SPACE;
        s_push.ota_open = true;
        return SIOT_OTA_R_NONE;
    }
    if (!s_store_ok) return SIOT_OTA_R_NO_SPACE;
    char path[24];
    path_for(img->family, "tmp", path);
    unlink(path);
    /* The stored image of this family makes room for the new one only when
     * both do not fit: until the new one is verified the old one is the
     * image the site can still be given. */
    uint64_t total = 0, free_b = 0;
    esp_vfs_fat_info(FW_MOUNT, &total, &free_b);
    if (free_b < (uint64_t)img->size + 8192) {
        char old[24];
        path_for(img->family, "inf", old); unlink(old);
        path_for(img->family, "bin", old); unlink(old);
        esp_vfs_fat_info(FW_MOUNT, &total, &free_b);
        if (free_b < (uint64_t)img->size + 8192) return SIOT_OTA_R_NO_SPACE;
        ESP_LOGW(TAG, "the stored %s image was removed to make room", family_name(img->family));
    }
    s_push.fp = fopen(path, "wb");
    return s_push.fp ? SIOT_OTA_R_NONE : SIOT_OTA_R_NO_SPACE;
}

static bool target_write(const uint8_t *data, size_t len)
{
    if (s_push.img.family == SAFR_FAMILY_BOARD) return esp_ota_write(s_push.ota, data, len) == ESP_OK;
    return fwrite(data, 1, len, s_push.fp) == len;
}

/* The app description of the image, from its first bytes: is this the image
 * of `family`, and the version OTA_PUSH_BEGIN announced? */
static siot_ota_reason_t check_description(const uint8_t *first, size_t len)
{
    if (len < APP_DESC_OFFSET + sizeof(esp_app_desc_t)) return SIOT_OTA_R_BAD_ARGS;
    esp_app_desc_t d;
    memcpy(&d, first + APP_DESC_OFFSET, sizeof(d));
    if (first[0] != ESP_IMAGE_HEADER_MAGIC || d.magic_word != ESP_APP_DESC_MAGIC_WORD) return SIOT_OTA_R_WRONG_FAMILY;
    d.project_name[sizeof(d.project_name) - 1] = '\0';
    d.version[sizeof(d.version) - 1] = '\0';
    char want[24];
    snprintf(want, sizeof(want), "sempreiot-%s", family_name(s_push.img.family));
    if (strcmp(d.project_name, want) != 0) {
        ESP_LOGE(TAG, "the image is '%s', the push said %s", d.project_name, want);
        return SIOT_OTA_R_WRONG_FAMILY;
    }
    if (strcmp(d.version, s_push.img.version) != 0) {
        ESP_LOGE(TAG, "the image is version '%s', the push said '%s'", d.version, s_push.img.version);
        return SIOT_OTA_R_BAD_VERSION;
    }
    return SIOT_OTA_R_NONE;
}

/* A stored image is not in an app partition, so the IDF image verifier cannot
 * look at it: the same check by hand. The signature of a Secure Boot V2 image
 * covers everything before its last 4 KB sector, which holds the signature. */
static siot_ota_reason_t verify_stored_signature(const uint8_t digest[32])
{
#if CONFIG_SECURE_SIGNED_APPS_NO_SECURE_BOOT || CONFIG_SECURE_BOOT_V2_ENABLED
    uint8_t verified[ESP_SECURE_BOOT_DIGEST_LEN];
    const esp_err_t err = esp_secure_boot_verify_sbv2_signature_block(
        (const ets_secure_boot_signature_t *)s_push.sig, digest, verified);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "signature: not signed by the key this board trusts (%s)", esp_err_to_name(err));
        return SIOT_OTA_R_SIG_FAIL;
    }
    return SIOT_OTA_R_NONE;
#else
    (void)digest;
    ESP_LOGW(TAG, "UNSIGNED board build: the stored image's signature is NOT checked");
    return SIOT_OTA_R_NONE;
#endif
}

/* ---- 4. OTA_PUSH_BEGIN / CHUNK / END ------------------------------------------------- */

static void on_begin(const siot_safr_frame_t *f)
{
    siot_ota_image_t img;
    if (!siot_ota_push_begin_decode(f->payload, f->payload_len, &img) || img.chunk < MIN_CHUNK) {
        siot_coordinator_ack_tablet(f->msg_id, SAFR_ACK_ERROR, SIOT_OTA_R_BAD_ARGS);
        return;
    }
    if (s_push.active && s_push.verify) {
        siot_coordinator_ack_tablet(f->msg_id, SAFR_ACK_ERROR, SIOT_OTA_R_BUSY);
        return;
    }
    /* The same image again = "where were we?" (a cable pulled, a retry of BEGIN). */
    if (s_push.active && s_push.img.family == img.family && s_push.img.size == img.size &&
        memcmp(s_push.img.sha256, img.sha256, SIOT_OTA_SHA_LEN) == 0) {
        s_push.last_ms = now_ms();
        ESP_LOGW(TAG, "push of %s %s resumes at chunk %lu", family_name(img.family), img.version,
                 (unsigned long)s_push.next_seq);
        send_result(SIOT_OTA_PUSH_RECEIVING, SIOT_OTA_R_NONE, img.family, s_push.next_seq, img.version);
        siot_coordinator_ack_tablet(f->msg_id, SAFR_ACK_OK, SIOT_OTA_R_NONE);
        return;
    }
    push_drop("another push begins");

    siot_ota_reason_t why = SIOT_OTA_R_NONE;
    if (s_reboot_at_ms != 0) why = SIOT_OTA_R_BUSY;
    else if (img.family == SAFR_FAMILY_BOARD) {
        if (s_selftest) why = SIOT_OTA_R_BUSY; /* the image running now is not confirmed yet */
        else if (siot_coordinator_alarm_recent()) why = SIOT_OTA_R_BUSY_ALARM;
        else why = siot_ota_accept_version(siot_version_string(), img.version,
                                           ANY_VERSION || (img.flags & SIOT_OTA_F_FORCE) != 0,
                                           ANY_VERSION || FORCE_ALLOWED);
        if (why == SIOT_OTA_R_NONE && ANY_VERSION) {
            ESP_LOGE(TAG, "TEST BUILD: version rule OFF — taking %s over %s without comparing them",
                     img.version, siot_version_string());
        }
    } else {
        siot_ota_version_t v;
        if (ota_rollout_busy(img.family)) why = SIOT_OTA_R_BUSY; /* it is being handed out (§13.6) */
        else if (!siot_ota_version_parse(img.version, &v)) why = SIOT_OTA_R_BAD_VERSION;
        /* a signed image: whole sectors, the last one is the signature */
        else if (img.size <= SIG_SECTOR || img.size % SIG_SECTOR != 0) why = SIOT_OTA_R_BAD_ARGS;
    }
    if (why == SIOT_OTA_R_NONE) {
        s_push.img = img;
        s_push.buf = malloc(img.chunk);
        s_push.sig = malloc(SIG_SECTOR);
        if (s_push.buf == NULL || s_push.sig == NULL) why = SIOT_OTA_R_NO_SPACE;
        else why = target_open();
    }
    if (why != SIOT_OTA_R_NONE) {
        ESP_LOGW(TAG, "push of %s %s (%lu B) refused: reason %d", family_name(img.family), img.version,
                 (unsigned long)img.size, (int)why);
        free(s_push.buf);
        free(s_push.sig);
        if (s_push.fp) fclose(s_push.fp);
        memset(&s_push, 0, sizeof(s_push));
        siot_coordinator_ack_tablet(f->msg_id, SAFR_ACK_ERROR, (uint8_t)why);
        return;
    }
    mbedtls_sha256_init(&s_push.sha_all);
    mbedtls_sha256_init(&s_push.sha_signed);
    mbedtls_sha256_starts(&s_push.sha_all, 0);
    mbedtls_sha256_starts(&s_push.sha_signed, 0);
    s_push.active = true;
    s_push.last_ms = now_ms();
    ESP_LOGW(TAG, "push begins: %s %s, %lu B in chunks of %u → %s", family_name(img.family), img.version,
             (unsigned long)img.size, img.chunk,
             img.family == SAFR_FAMILY_BOARD ? s_push.part->label : FW_PARTITION);
    /* RESULT before the ACK: when the tablet has the ACK it already knows where to start. */
    send_result(SIOT_OTA_PUSH_RECEIVING, SIOT_OTA_R_NONE, img.family, 0, img.version);
    siot_coordinator_ack_tablet(f->msg_id, SAFR_ACK_OK, SIOT_OTA_R_NONE);
}

static void fail_push(uint16_t msg_id, siot_ota_reason_t why)
{
    const uint8_t family = s_push.img.family;
    char version[SIOT_OTA_VER_MAX_LEN + 1];
    strlcpy(version, s_push.img.version, sizeof(version));
    push_drop("failed");
    send_result(SIOT_OTA_PUSH_FAILED, (uint8_t)why, family, 0, version);
    siot_coordinator_ack_tablet(msg_id, SAFR_ACK_ERROR, (uint8_t)why);
}

/* The whole chunk is in s_push.buf. */
static void chunk_complete(void)
{
    const siot_ota_chunk_t *c = &s_push.cur;
    if (siot_ota_crc32(s_push.buf, c->len) != c->crc32) {
        ESP_LOGW(TAG, "chunk %lu: bad CRC, the tablet sends it again", (unsigned long)c->seq);
        siot_coordinator_ack_tablet(s_push.cur_msg_id, SAFR_ACK_ERROR, SIOT_OTA_R_BAD_CRC);
        return;
    }
    if (c->seq == 0) {
        const siot_ota_reason_t why = check_description(s_push.buf, c->len);
        if (why != SIOT_OTA_R_NONE) { fail_push(s_push.cur_msg_id, why); return; }
    }
    if (!target_write(s_push.buf, c->len)) {
        ESP_LOGE(TAG, "chunk %lu: write failed", (unsigned long)c->seq);
        fail_push(s_push.cur_msg_id, SIOT_OTA_R_NO_SPACE);
        return;
    }
    mbedtls_sha256_update(&s_push.sha_all, s_push.buf, c->len);
    /* What the signature covers, and the signature sector itself, by file offset. */
    const uint32_t start = s_push.received, end = start + c->len;
    const uint32_t sig_at = s_push.img.size - SIG_SECTOR;
    if (start < sig_at) {
        const uint32_t n = (end < sig_at ? end : sig_at) - start;
        mbedtls_sha256_update(&s_push.sha_signed, s_push.buf, n);
    }
    if (end > sig_at) {
        const uint32_t from = start > sig_at ? start : sig_at;
        memcpy(s_push.sig + (from - sig_at), s_push.buf + (from - start), end - from);
    }
    s_push.received = end;
    s_push.next_seq++;
    s_push.last_ms = now_ms();
    if ((c->seq & 0x0F) == 0 || s_push.received == s_push.img.size) {
        ESP_LOGI(TAG, "chunk %lu: %lu / %lu B (%lu %%)", (unsigned long)c->seq, (unsigned long)s_push.received,
                 (unsigned long)s_push.img.size, (unsigned long)((uint64_t)s_push.received * 100 / s_push.img.size));
    }
    siot_coordinator_ack_tablet(s_push.cur_msg_id, SAFR_ACK_OK, SIOT_OTA_R_NONE);
}

/* The raw bytes after an OTA_PUSH_CHUNK frame (serial rx task). */
static void on_raw(const uint8_t *data, size_t len, size_t left, void *ctx)
{
    (void)ctx;
    xSemaphoreTake(s_lock, portMAX_DELAY);
    if (data == NULL) { /* the tablet went silent mid-chunk: no ACK, it sends the chunk again */
        s_push.cur_fill = 0;
        xSemaphoreGive(s_lock);
        return;
    }
    if (s_push.active && s_push.cur_store) {
        if (s_push.cur_fill + len <= s_push.img.chunk) memcpy(s_push.buf + s_push.cur_fill, data, len);
        s_push.cur_fill += len;
        if (left == 0) chunk_complete();
    }
    xSemaphoreGive(s_lock);
}

static void on_chunk(const siot_safr_frame_t *f)
{
    siot_ota_chunk_t c;
    if (!siot_ota_chunk_decode(f->payload, f->payload_len, &c)) {
        siot_coordinator_ack_tablet(f->msg_id, SAFR_ACK_ERROR, SIOT_OTA_R_BAD_ARGS);
        return; /* no length to trust: whatever follows is scanned as frames and fails their CRC */
    }
    s_push.cur = c;
    s_push.cur_msg_id = f->msg_id;
    s_push.cur_fill = 0;
    s_push.cur_store = false;
    /* The bytes are on the wire whatever we think of the header: always read them. */
    if (siot_link_serial_expect_raw(c.len, on_raw, NULL) != ESP_OK) {
        siot_coordinator_ack_tablet(f->msg_id, SAFR_ACK_ERROR, SIOT_OTA_R_BUSY);
        return;
    }
    if (!s_push.active) {
        siot_coordinator_ack_tablet(f->msg_id, SAFR_ACK_ERROR, SIOT_OTA_R_OUT_OF_ORDER);
        send_result(SIOT_OTA_PUSH_FAILED, SIOT_OTA_R_OUT_OF_ORDER, 0, 0, "");
        return;
    }
    if (s_push.verify) { /* END was heard: nothing more belongs to this push */
        siot_coordinator_ack_tablet(f->msg_id, SAFR_ACK_ERROR, SIOT_OTA_R_BUSY);
        return;
    }
    s_push.last_ms = now_ms();
    if (c.seq < s_push.next_seq) { /* a repeat of what is written: its ACK was lost */
        siot_coordinator_ack_tablet(f->msg_id, SAFR_ACK_OK, SIOT_OTA_R_NONE);
        return;
    }
    const uint32_t remaining = s_push.img.size - s_push.received;
    const uint32_t want = remaining < s_push.img.chunk ? remaining : s_push.img.chunk;
    if (c.seq > s_push.next_seq || c.len != want) {
        ESP_LOGW(TAG, "chunk %lu (%u B) while waiting for chunk %lu (%lu B)", (unsigned long)c.seq, c.len,
                 (unsigned long)s_push.next_seq, (unsigned long)want);
        send_result(SIOT_OTA_PUSH_RECEIVING, SIOT_OTA_R_OUT_OF_ORDER, s_push.img.family, s_push.next_seq,
                    s_push.img.version);
        siot_coordinator_ack_tablet(f->msg_id, SAFR_ACK_ERROR, SIOT_OTA_R_OUT_OF_ORDER);
        return;
    }
    s_push.cur_store = true; /* on_raw fills the buffer; chunk_complete() ACKs */
}

static void on_end(const siot_safr_frame_t *f)
{
    if (!s_push.active) {
        siot_coordinator_ack_tablet(f->msg_id, SAFR_ACK_ERROR, SIOT_OTA_R_OUT_OF_ORDER);
        return;
    }
    if (s_push.received != s_push.img.size) {
        send_result(SIOT_OTA_PUSH_RECEIVING, SIOT_OTA_R_OUT_OF_ORDER, s_push.img.family, s_push.next_seq,
                    s_push.img.version);
        siot_coordinator_ack_tablet(f->msg_id, SAFR_ACK_ERROR, SIOT_OTA_R_OUT_OF_ORDER);
        return;
    }
    /* Heard; the verdict is OTA_PUSH_RESULT. Checking ~1 MB takes a second or
     * two: not in this task, which holds the dispatcher both links share. */
    s_push.verify = true;
    s_push.last_ms = now_ms();
    siot_coordinator_ack_tablet(f->msg_id, SAFR_ACK_OK, SIOT_OTA_R_NONE);
}

/* s_lock held, in the 1 s task. */
static void push_verdict(void)
{
    const siot_ota_image_t img = s_push.img;
    uint8_t all[32], signed_part[32];
    mbedtls_sha256_finish(&s_push.sha_all, all);
    mbedtls_sha256_finish(&s_push.sha_signed, signed_part);
    siot_ota_reason_t why = SIOT_OTA_R_NONE;
    if (memcmp(all, img.sha256, SIOT_OTA_SHA_LEN) != 0) {
        ESP_LOGE(TAG, "SHA-256 of what arrived is not the one announced");
        why = SIOT_OTA_R_SHA_FAIL;
    }
    if (why == SIOT_OTA_R_NONE && img.family == SAFR_FAMILY_BOARD) {
        /* esp_ota_end verifies the image and, with signed apps, its signature. */
        const esp_err_t err = esp_ota_end(s_push.ota);
        s_push.ota_open = false;
        if (err != ESP_OK) {
            ESP_LOGE(TAG, "image refused: %s", esp_err_to_name(err));
            why = SIOT_OTA_R_SIG_FAIL;
        } else if (siot_coordinator_alarm_recent()) {
            why = SIOT_OTA_R_BUSY_ALARM; /* an alarm came in during the transfer: no restart now */
        } else if (esp_ota_set_boot_partition(s_push.part) != ESP_OK) {
            why = SIOT_OTA_R_SIG_FAIL;
        }
    } else if (why == SIOT_OTA_R_NONE) {
        why = verify_stored_signature(signed_part);
        char tmp[24], bin[24], inf[24];
        path_for(img.family, "tmp", tmp);
        path_for(img.family, "bin", bin);
        path_for(img.family, "inf", inf);
        const bool closed = fclose(s_push.fp) == 0;
        s_push.fp = NULL;
        if (why == SIOT_OTA_R_NONE && !closed) why = SIOT_OTA_R_NO_SPACE;
        if (why == SIOT_OTA_R_NONE) {
            unlink(inf); /* from here to the new .inf there is no stored image of this family */
            unlink(bin);
            if (rename(tmp, bin) != 0 || !store_info_write(&img)) why = SIOT_OTA_R_NO_SPACE;
        }
        if (why != SIOT_OTA_R_NONE) unlink(tmp);
    }

    if (why != SIOT_OTA_R_NONE) {
        push_drop("verification failed");
        send_result(SIOT_OTA_PUSH_FAILED, (uint8_t)why, img.family, 0, img.version);
        return;
    }
    mbedtls_sha256_free(&s_push.sha_all);
    mbedtls_sha256_free(&s_push.sha_signed);
    free(s_push.buf);
    free(s_push.sig);
    memset(&s_push, 0, sizeof(s_push));
    send_result(SIOT_OTA_PUSH_OK, SIOT_OTA_R_NONE, img.family, 0, img.version);
    if (img.family == SAFR_FAMILY_BOARD) {
        ESP_LOGW(TAG, "board image %s verified: restarting into it", img.version);
        s_reboot_at_ms = now_ms() + REBOOT_DELAY_MS;
    } else {
        ESP_LOGW(TAG, "%s image %s verified and stored (%lu B)", family_name(img.family), img.version,
                 (unsigned long)img.size);
        s_stored_family = img.family; /* the rollout is told outside s_lock */
    }
}

/* ---- 5. OTA_BAUD, the sink ------------------------------------------------------------ */

static void on_baud(const siot_safr_frame_t *f)
{
    const size_t alen = f->payload_len >= 2 ? f->payload[1] : 0;
    const uint32_t baud = (alen == 4 && f->payload_len >= 6) ? siot_get_u32(&f->payload[2]) : 0;
    if (baud != 115200 && baud != 230400 && baud != 460800 && baud != 921600) {
        siot_coordinator_ack_tablet(f->msg_id, SAFR_ACK_ERROR, SIOT_OTA_R_BAD_ARGS);
        return;
    }
    siot_coordinator_ack_tablet(f->msg_id, SAFR_ACK_OK, SIOT_OTA_R_NONE); /* at the speed the tablet listens on */
    siot_link_serial_set_baud(baud);                                      /* waits for the ACK to leave */
}

static void ota_sink(const siot_safr_frame_t *f, bool dup, void *ctx)
{
    (void)ctx;
    xSemaphoreTake(s_lock, portMAX_DELAY);
    switch (f->msg_type) {
    case SAFR_MSG_OTA_PUSH_BEGIN: on_begin(f); break;
    case SAFR_MSG_OTA_PUSH_CHUNK: on_chunk(f); break; /* a repeat carries its bytes again: same path */
    case SAFR_MSG_OTA_PUSH_END:
        if (dup) siot_coordinator_ack_tablet(f->msg_id, SAFR_ACK_OK, SIOT_OTA_R_NONE);
        else on_end(f);
        break;
    case SAFR_MSG_COMMAND:
        if (f->payload[0] == SAFR_CMD_OTA_BAUD) on_baud(f);
        else if (f->payload[0] == SAFR_CMD_OTA_CONTROL) { if (!dup) ota_rollout_on_control(f); else siot_coordinator_ack_tablet(f->msg_id, SAFR_ACK_OK, SIOT_OTA_R_NONE); }
        else if (f->payload[0] == SAFR_CMD_GET_ROLLOUT) ota_rollout_on_get(f);
        else siot_coordinator_ack_tablet(f->msg_id, SAFR_ACK_ERROR, SIOT_OTA_R_BAD_ARGS); /* OTA_OFFER is the board's to send */
        break;
    default:
        break;
    }
    xSemaphoreGive(s_lock);
}

/* ---- 6. self-test, rollback report, the 1 s task ------------------------------------------ */

static void on_tablet_frame(siot_evt_id_t id, const void *data, void *ctx)
{
    (void)id; (void)ctx;
    const siot_evt_frame_t *ev = data;
    if (!siot_mac_eq(ev->src_mac, SAFR_CENTRAL_MAC)) return;
    xSemaphoreTake(s_lock, portMAX_DELAY);
    if (s_selftest) {
#if CONFIG_SIOT_OTA_SELFTEST_FAIL
        ESP_LOGE(TAG, "self-test: this build fails it on purpose (CONFIG_SIOT_OTA_SELFTEST_FAIL)");
#else
        /* OTA blueprint §4.4 for the board: the identity and the installation
         * code were read at boot (we would not be here without them), the
         * coordinator runs, and the tablet — the rescue path — is heard with a
         * frame that passed authentication. */
        if (siot_identity_valid() && siot_config_has_code()) {
            const esp_err_t err = esp_ota_mark_app_valid_cancel_rollback();
            ESP_LOGW(TAG, "self-test passed: %s is now the board's firmware (%s)", siot_version_string(),
                     esp_err_to_name(err));
            s_selftest = false;
            send_result(SIOT_OTA_PUSH_OK, SIOT_OTA_R_NONE, SAFR_FAMILY_BOARD, 0, siot_version_string());
        }
#endif
    }
    if (s_rollback_pending) {
        s_rollback_pending = false;
        ESP_LOGE(TAG, "telling the tablet: %s failed its self-test, the board runs %s", s_rollback_version,
                 siot_version_string());
        send_result(SIOT_OTA_PUSH_FAILED, SIOT_OTA_R_SELFTEST_FAIL, SAFR_FAMILY_BOARD, 0, s_rollback_version);
        nvs_handle_t h;
        if (nvs_open(NVS_NS, NVS_READWRITE, &h) == ESP_OK) {
            if (nvs_set_blob(h, NVS_KEY_REPORTED, s_rollback_id, sizeof(s_rollback_id)) == ESP_OK) nvs_commit(h);
            nvs_close(h);
        }
    }
    xSemaphoreGive(s_lock);
}

static void boot_state(void)
{
    const esp_partition_t *running = esp_ota_get_running_partition();
    esp_ota_img_states_t st = ESP_OTA_IMG_UNDEFINED;
    if (running && esp_ota_get_state_partition(running, &st) == ESP_OK && st == ESP_OTA_IMG_PENDING_VERIFY) {
        s_selftest = true;
        s_selftest_deadline_ms = now_ms() + (int64_t)CONFIG_SIOT_OTA_SELFTEST_S * 1000;
        ESP_LOGW(TAG, "first boot of %s from %s: self-test, %d s to hear the tablet", siot_version_string(),
                 running->label, CONFIG_SIOT_OTA_SELFTEST_S);
    }
    /* An image that was tried and thrown away, which the tablet was not told about yet. */
    const esp_partition_t *bad = esp_ota_get_last_invalid_partition();
    esp_app_desc_t d;
    if (bad != NULL && esp_ota_get_partition_description(bad, &d) == ESP_OK) {
        memcpy(s_rollback_id, d.app_elf_sha256, sizeof(s_rollback_id));
        uint8_t told[sizeof(s_rollback_id)] = {0};
        size_t len = sizeof(told);
        nvs_handle_t h;
        bool known = false;
        if (nvs_open(NVS_NS, NVS_READONLY, &h) == ESP_OK) {
            known = nvs_get_blob(h, NVS_KEY_REPORTED, told, &len) == ESP_OK && len == sizeof(told) &&
                    memcmp(told, s_rollback_id, sizeof(told)) == 0;
            nvs_close(h);
        }
        if (!known) {
            d.version[sizeof(d.version) - 1] = '\0';
            strlcpy(s_rollback_version, d.version, sizeof(s_rollback_version));
            s_rollback_pending = true;
            ESP_LOGE(TAG, "%s in %s was rolled back: this is %s again", s_rollback_version, bad->label,
                     siot_version_string());
        }
    }
}

static void ota_task(void *arg)
{
    (void)arg;
    for (;;) {
        vTaskDelay(pdMS_TO_TICKS(500));
        const int64_t t = now_ms();
        xSemaphoreTake(s_lock, portMAX_DELAY);
        if (s_push.active && s_push.verify) push_verdict();
        const uint8_t stored = s_stored_family;
        s_stored_family = 0;
        if (s_push.active && t - s_push.last_ms > STALL_MS) push_drop("nobody continued it");
        const bool reboot = s_reboot_at_ms != 0 && t >= s_reboot_at_ms;
        const bool rollback = s_selftest && t >= s_selftest_deadline_ms;
        xSemaphoreGive(s_lock);
        if (stored) ota_rollout_on_stored(stored);
        ota_rollout_tick(t);
        if (rollback) {
            ESP_LOGE(TAG, "self-test: the tablet was not heard in %d s → back to the previous firmware",
                     CONFIG_SIOT_OTA_SELFTEST_S);
            vTaskDelay(pdMS_TO_TICKS(100));
            esp_ota_mark_app_invalid_rollback_and_reboot(); /* does not return when it works */
            ESP_LOGE(TAG, "rollback refused: no other image to go back to");
            xSemaphoreTake(s_lock, portMAX_DELAY);
            s_selftest = false;
            xSemaphoreGive(s_lock);
        }
        if (reboot) {
            siot_link_serial_set_baud(115200); /* the new image starts at the default speed */
            vTaskDelay(pdMS_TO_TICKS(50));
            esp_restart();
        }
    }
}

esp_err_t siot_ota_board_init(void)
{
    if (s_lock == NULL) s_lock = xSemaphoreCreateMutex();
    if (s_lock == NULL) return ESP_ERR_NO_MEM;
    store_mount();
    boot_state();
    if (ota_rollout_init() != ESP_OK) return ESP_ERR_NO_MEM;
    esp_err_t err = siot_evbus_subscribe(SIOT_EVT_SAFR_RX, on_tablet_frame, NULL, NULL);
    if (err != ESP_OK) return err;
    siot_coordinator_set_ota_sink(ota_sink, NULL);
    if (xTaskCreatePinnedToCore(ota_task, "siot_ota", 8192, NULL, 5, NULL, 0) /* RSA-3072 verify runs here */ != pdPASS) return ESP_ERR_NO_MEM;
    ESP_LOGI(TAG, "ready: %s, FORCE %s", s_store_ok ? "own image + fw_store" : "own image only",
             FORCE_ALLOWED ? "honoured (bench)" : "refused");
    if (ANY_VERSION) {
        ESP_LOGE(TAG, "TEST BUILD: this board accepts ANY firmware version, the same or an older one. "
                      "NOT FOR PRODUCTION (docs/ota/before-production.md)");
    }
    return ESP_OK;
}
