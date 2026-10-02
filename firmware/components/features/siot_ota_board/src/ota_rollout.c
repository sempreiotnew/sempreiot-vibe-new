/* ota_rollout — the board sends a stored image to the units, one at a time
 * (protocol §13.4, §13.6; OTA blueprint §3.4). Layout of this file:
 *   1. state, persistence      3. what comes up from the mesh
 *   2. OTA_ROLLOUT pages       4. OTA_CONTROL / GET_ROLLOUT, the tick
 * One rollout at a time. Callers: the serial rx task (tablet commands), the
 * mesh rx task (units), the OTA task (tick). s_lock guards s_ro. */
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#include "esp_log.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "sdkconfig.h"

#include "ota_internal.h"
#include "siot_coordinator.h"
#include "siot_devtab.h"
#include "siot_ota_board.h"
#include "siot_util.h"

static const char *TAG = "siot_ota_ro";

#define DEADLINE_S        300    /* UPDATING instead of missing for this long (§13.4) */
#define OFFER_ACK_MS      5000   /* an offer nobody ACKed is sent again */
/* A leaf answers on its next wake (§13.5): one wake interval plus its budget
 * to hear the offer, and pull wake + sleep + self-test wake to finish. */
#define LEAF_DEADLINE_S   600
#define LEAF_OFFER_ACK_MS 90000
#define OFFER_TRIES       3
#define FIRST_STATUS_MS   30000  /* ACK OK and then nothing: a unit that knows no OTA */
#define PAGE_EVERY_MS     5000
#define MAX_ATTEMPTS      2
#define ROLLOUT_FILE      OTA_FW_MOUNT "/rollout.dat"
#define ROLLOUT_MAGIC     0x524F4C31u /* "ROL1" */

/* ---- 1. state ---------------------------------------------------------------------- */

typedef struct {
    uint8_t  mac[6];
    uint16_t product;
    uint8_t  state;          /* siot_ota_unit_state_t */
    uint8_t  percent;
    uint8_t  attempts;
    uint8_t  reason;
    char     version[SIOT_OTA_VER_MAX_LEN + 1]; /* what the unit runs */
    /* RAM only */
    int64_t  changed_ms;
    int64_t  offered_ms;     /* the first offer of this attempt */
    int64_t  last_offer_ms;
    int64_t  acked_ms;       /* 0 = the offer is not ACKed yet */
    uint16_t offer_msg_id;
    uint8_t  offer_tries;
    bool     status_seen;
} unit_t;

typedef struct {
    uint8_t  state;          /* siot_ota_rollout_state_t */
    uint8_t  family;
    siot_ota_image_t img;    /* what is offered */
    uint16_t n;
    int      cur;            /* the unit being updated, -1 = none */
    bool     aborted;
    int64_t  next_page_ms;
    unit_t  *u;              /* SIOT_DEVTAB_CAP entries, allocated at the first start */
} rollout_t;

static rollout_t s_ro = {.cur = -1};
static SemaphoreHandle_t s_lock;
static siot_devtab_entry_t *s_snap; /* scratch for the device table */

static int64_t now_ms(void) { return esp_timer_get_time() / 1000; }

static bool unit_settled(const unit_t *u)
{
    return u->state == SIOT_OTA_U_DONE || u->state == SIOT_OTA_U_FAILED || u->state == SIOT_OTA_U_SKIPPED;
}

static uint16_t deadline_s(uint8_t family) { return family == SAFR_FAMILY_LEAF ? LEAF_DEADLINE_S : DEADLINE_S; }
static int64_t  offer_ack_ms(uint8_t family) { return family == SAFR_FAMILY_LEAF ? LEAF_OFFER_ACK_MS : OFFER_ACK_MS; }

static void set_state(unit_t *u, uint8_t state, uint8_t reason)
{
    u->state = state;
    u->reason = reason;
    u->changed_ms = now_ms();
}

static int find_unit(const uint8_t mac[6])
{
    for (int i = 0; i < s_ro.n; i++) if (siot_mac_eq(s_ro.u[i].mac, mac)) return i;
    return -1;
}

/* What survives a restart: the header and, per unit, what is settled. */
typedef struct __attribute__((packed)) {
    uint32_t magic;
    uint8_t  state, family, aborted, reserved;
    uint16_t n;
    uint32_t size;
    uint8_t  sha256[SIOT_OTA_SHA_LEN];
    char     target[SIOT_OTA_VER_MAX_LEN + 1];
} file_hdr_t;

typedef struct __attribute__((packed)) {
    uint8_t  mac[6];
    uint16_t product;
    uint8_t  state, attempts, reason;
    char     version[SIOT_OTA_VER_MAX_LEN + 1];
} file_unit_t;

static void persist(void)
{
    if (!ota_store_ok()) return;
    if (s_ro.state == SIOT_OTA_RO_IDLE || s_ro.state == SIOT_OTA_RO_STAGED) {
        unlink(ROLLOUT_FILE);
        return;
    }
    FILE *f = fopen(ROLLOUT_FILE, "wb");
    if (f == NULL) { ESP_LOGW(TAG, "rollout.dat: cannot write"); return; }
    file_hdr_t h = {.magic = ROLLOUT_MAGIC, .state = s_ro.state, .family = s_ro.family,
                    .aborted = s_ro.aborted, .n = s_ro.n, .size = s_ro.img.size};
    memcpy(h.sha256, s_ro.img.sha256, sizeof(h.sha256));
    strlcpy(h.target, s_ro.img.version, sizeof(h.target));
    bool ok = fwrite(&h, sizeof(h), 1, f) == 1;
    for (int i = 0; ok && i < s_ro.n; i++) {
        const unit_t *u = &s_ro.u[i];
        file_unit_t fu = {.product = u->product, .state = u->state, .attempts = u->attempts, .reason = u->reason};
        memcpy(fu.mac, u->mac, 6);
        strlcpy(fu.version, u->version, sizeof(fu.version));
        ok = fwrite(&fu, sizeof(fu), 1, f) == 1;
    }
    if (fclose(f) != 0 || !ok) ESP_LOGW(TAG, "rollout.dat: write failed");
}

static bool alloc_units(void)
{
    if (s_ro.u == NULL) s_ro.u = calloc(SIOT_DEVTAB_CAP, sizeof(unit_t));
    if (s_snap == NULL) s_snap = malloc(SIOT_DEVTAB_CAP * sizeof(siot_devtab_entry_t));
    return s_ro.u != NULL && s_snap != NULL;
}

/* After a restart: the rollout that was running goes on, paused, from the
 * first unit that is not settled (§13.6). */
static void restore(void)
{
    if (!ota_store_ok()) return;
    FILE *f = fopen(ROLLOUT_FILE, "rb");
    if (f == NULL) return;
    file_hdr_t h;
    bool ok = fread(&h, sizeof(h), 1, f) == 1 && h.magic == ROLLOUT_MAGIC && h.n <= SIOT_DEVTAB_CAP &&
              h.state < SIOT_OTA_RO__COUNT && alloc_units();
    /* the image it was offering must still be the one in the store */
    char v[SIOT_OTA_VER_MAX_LEN + 1];
    uint32_t size = 0;
    uint8_t sha[SIOT_OTA_SHA_LEN];
    h.target[SIOT_OTA_VER_MAX_LEN] = '\0';
    ok = ok && siot_ota_board_stored(h.family, v, &size, sha) && size == h.size &&
         memcmp(sha, h.sha256, sizeof(sha)) == 0;
    if (ok) {
        memset(&s_ro.img, 0, sizeof(s_ro.img));
        s_ro.family = s_ro.img.family = h.family;
        s_ro.img.size = h.size;
        s_ro.img.deadline_s = deadline_s(h.family);
        memcpy(s_ro.img.sha256, h.sha256, sizeof(h.sha256));
        strlcpy(s_ro.img.version, h.target, sizeof(s_ro.img.version));
        s_ro.aborted = h.aborted;
        s_ro.n = 0;
        for (uint16_t i = 0; i < h.n; i++) {
            file_unit_t fu;
            if (fread(&fu, sizeof(fu), 1, f) != 1) { ok = false; break; }
            unit_t *u = &s_ro.u[s_ro.n++];
            memset(u, 0, sizeof(*u));
            memcpy(u->mac, fu.mac, 6);
            u->product = fu.product;
            u->attempts = fu.attempts;
            fu.version[SIOT_OTA_VER_MAX_LEN] = '\0';
            strlcpy(u->version, fu.version, sizeof(u->version));
            /* a unit that was in the middle of it starts that attempt again */
            const bool settled = fu.state == SIOT_OTA_U_DONE || fu.state == SIOT_OTA_U_FAILED ||
                                 fu.state == SIOT_OTA_U_SKIPPED;
            set_state(u, settled ? fu.state : SIOT_OTA_U_WAITING, settled ? fu.reason : SIOT_OTA_R_NONE);
        }
    }
    fclose(f);
    if (!ok) {
        ESP_LOGW(TAG, "rollout.dat: unreadable or for another image, dropped");
        unlink(ROLLOUT_FILE);
        s_ro.n = 0;
        s_ro.state = SIOT_OTA_RO_IDLE;
        return;
    }
    const bool running = h.state == SIOT_OTA_RO_ROLLING || h.state == SIOT_OTA_RO_PAUSED;
    s_ro.state = running ? SIOT_OTA_RO_PAUSED : h.state;
    s_ro.cur = -1;
    ESP_LOGW(TAG, "rollout of %s %s restored: %u unit(s), %s", ota_family_name(s_ro.family), s_ro.img.version,
             s_ro.n, running ? "PAUSED until the tablet says resume" : "finished");
    if (running) ota_server_start();
}

/* ---- 2. OTA_ROLLOUT pages ------------------------------------------------------------ */

static void fill_entry(const unit_t *u, int64_t t, siot_ota_rollout_entry_t *e)
{
    memset(e, 0, sizeof(*e));
    memcpy(e->mac, u->mac, 6);
    e->product = u->product;
    e->state = u->state;
    e->percent = u->percent;
    e->attempts = u->attempts;
    e->reason = u->reason;
    const int64_t age = (t - u->changed_ms) / 1000;
    e->age_s = u->changed_ms == 0 ? 0xFFFF : (uint16_t)(age > 0xFFFE ? 0xFFFE : age < 0 ? 0 : age);
    strlcpy(e->version, u->version, sizeof(e->version));
}

/* `page` 0 = every page. s_lock held. */
static void send_pages_of_rollout(uint8_t page)
{
    const int64_t t = now_ms();
    uint8_t p[SAFR_MAX_PAYLOAD];
    siot_ota_rollout_hdr_t h = {.total = s_ro.n, .state = s_ro.state, .family = s_ro.family};
    strlcpy(h.target, s_ro.img.version, sizeof(h.target));
    const size_t hdr_len = 7 + 1 + strnlen(h.target, SIOT_OTA_VER_MAX_LEN);

    /* where each page starts */
    uint16_t starts[64];
    uint8_t pages = 0;
    int i = 0;
    do {
        if (pages >= 64) break;
        starts[pages++] = (uint16_t)i;
        size_t used = hdr_len;
        while (i < s_ro.n) {
            siot_ota_rollout_entry_t e;
            fill_entry(&s_ro.u[i], t, &e);
            const size_t l = siot_ota_rollout_entry_len(&e);
            if (used + l > SAFR_MAX_PAYLOAD) break;
            used += l;
            i++;
        }
    } while (i < s_ro.n);

    for (uint8_t pg = 1; pg <= pages; pg++) {
        if (page != 0 && page != pg) continue;
        const int first = starts[pg - 1];
        const int end = pg < pages ? starts[pg] : s_ro.n;
        h.page = pg;
        h.page_count = pages;
        h.count = (uint8_t)(end - first);
        size_t off = siot_ota_rollout_hdr_encode(p, &h);
        for (int k = first; k < end; k++) {
            siot_ota_rollout_entry_t e;
            fill_entry(&s_ro.u[k], t, &e);
            off += siot_ota_rollout_entry_encode(&p[off], &e);
        }
        siot_coordinator_send_to_tablet(SAFR_MSG_OTA_ROLLOUT, 0, p, off);
    }
}

/* A family that holds an image and has no rollout: "staged", nothing else. */
static void send_staged(uint8_t family)
{
    char v[SIOT_OTA_VER_MAX_LEN + 1];
    if (!siot_ota_board_stored(family, v, NULL, NULL)) return;
    siot_ota_rollout_hdr_t h = {.page = 1, .page_count = 1, .state = SIOT_OTA_RO_STAGED, .family = family};
    strlcpy(h.target, v, sizeof(h.target));
    uint8_t p[SAFR_MAX_PAYLOAD];
    siot_coordinator_send_to_tablet(SAFR_MSG_OTA_ROLLOUT, 0, p, siot_ota_rollout_hdr_encode(p, &h));
}

/* s_lock held. */
static void send_everything(uint8_t page)
{
    const bool has_rollout = s_ro.state != SIOT_OTA_RO_IDLE && s_ro.state != SIOT_OTA_RO_STAGED;
    bool any = false;
    for (uint8_t f = SAFR_FAMILY_NODE; f <= SAFR_FAMILY_LEAF; f++) {
        if (has_rollout && f == s_ro.family) { send_pages_of_rollout(page); any = true; }
        else if (siot_ota_board_stored(f, NULL, NULL, NULL)) { send_staged(f); any = true; }
    }
    if (!any) { /* nothing stored, nothing rolling: say so, the tablet is waiting for an answer */
        const siot_ota_rollout_hdr_t h = {.page = 1, .page_count = 1, .state = SIOT_OTA_RO_IDLE,
                                          .family = SAFR_FAMILY_NODE};
        uint8_t p[SAFR_MAX_PAYLOAD];
        siot_coordinator_send_to_tablet(SAFR_MSG_OTA_ROLLOUT, 0, p, siot_ota_rollout_hdr_encode(p, &h));
    }
}

static void changed(bool save)
{
    if (save) persist();
    send_pages_of_rollout(0);
    s_ro.next_page_ms = now_ms() + PAGE_EVERY_MS;
}

/* ---- 3. what comes up from the mesh ---------------------------------------------------- */

static void finish_if_done(void)
{
    if (s_ro.cur >= 0) return;
    for (int i = 0; i < s_ro.n; i++) if (!unit_settled(&s_ro.u[i])) return;
    bool failed = false, skipped_by_abort = false;
    int done = 0;
    for (int i = 0; i < s_ro.n; i++) {
        if (s_ro.u[i].state == SIOT_OTA_U_FAILED) failed = true;
        if (s_ro.u[i].state == SIOT_OTA_U_SKIPPED && s_ro.u[i].reason == SIOT_OTA_R_ABORTED) skipped_by_abort = true;
        if (s_ro.u[i].state == SIOT_OTA_U_DONE) done++;
    }
    s_ro.state = (failed || skipped_by_abort) ? SIOT_OTA_RO_PARTIAL : SIOT_OTA_RO_DONE;
    ESP_LOGW(TAG, "rollout of %s %s ended: %s, %d of %u updated", ota_family_name(s_ro.family), s_ro.img.version,
             s_ro.state == SIOT_OTA_RO_DONE ? "DONE" : "PARTIAL", done, s_ro.n);
    ota_server_stop();
}

/* The attempt on the current unit ended without the new image running. */
static void attempt_failed(unit_t *u, uint8_t reason)
{
    char m[SIOT_MAC_STR_LEN];
    if (reason == SIOT_OTA_R_NOT_NEWER) { /* it already runs it: not a failure (§13.6) */
        ESP_LOGW(TAG, "%s: already runs %s or newer, skipped", siot_mac_to_str(u->mac, m), s_ro.img.version);
        set_state(u, SIOT_OTA_U_SKIPPED, reason);
    } else {
        u->attempts++;
        /* The image ran on the unit and was thrown away (self-test, a reset before it
         * ended, or never booted): the same image will do the same again — final, so the
         * rollout does not wait another download and self-test for nothing (§13.6). */
        const bool image_bad = reason == SIOT_OTA_R_SELFTEST_FAIL || reason == SIOT_OTA_R_NOT_VALIDATED ||
                               reason == SIOT_OTA_R_NOT_BOOTED;
        const bool again = u->attempts < MAX_ATTEMPTS && !s_ro.aborted && !image_bad;
        ESP_LOGW(TAG, "%s: attempt %u failed, reason %u → %s", siot_mac_to_str(u->mac, m), u->attempts, reason,
                 again ? "once more, after the others" : "FAILED");
        set_state(u, again ? SIOT_OTA_U_WAITING : SIOT_OTA_U_FAILED, reason);
    }
    u->percent = 0;
    s_ro.cur = -1;
    finish_if_done();
    changed(true);
}

static void on_uplink(const siot_safr_frame_t *f, bool dup, void *ctx)
{
    (void)ctx;
    xSemaphoreTake(s_lock, portMAX_DELAY);
    const bool live = s_ro.state == SIOT_OTA_RO_ROLLING || s_ro.state == SIOT_OTA_RO_PAUSED;
    const int i = s_ro.n ? find_unit(f->src_mac) : -1;
    unit_t *u = i >= 0 ? &s_ro.u[i] : NULL;
    char m[SIOT_MAC_STR_LEN];

    if (f->msg_type == SAFR_MSG_OTA_RESULT) {
        /* ours to acknowledge, rollout or not: the unit repeats it until somebody does */
        if (f->flags & SAFR_F_ACK_REQ) siot_coordinator_ack_unit(f->src_mac, f->msg_id, SAFR_ACK_OK, 0);
        siot_ota_result_t r;
        if (!dup && u != NULL && siot_ota_result_decode(f->payload, f->payload_len, &r)) {
            strlcpy(u->version, r.version, sizeof(u->version));
            siot_devtab_set_product(u->mac, 0, 0, r.version); /* the table's version follows */
            if (r.ok) {
                ESP_LOGW(TAG, "%s: runs %s", siot_mac_to_str(u->mac, m), r.version);
                u->percent = 100;
                set_state(u, SIOT_OTA_U_DONE, SIOT_OTA_R_NONE);
                if (s_ro.cur == i) s_ro.cur = -1;
                if (live) finish_if_done();
                changed(true);
            } else if (s_ro.cur == i) {
                ESP_LOGW(TAG, "%s: failed, reason %u detail %u, runs %s", siot_mac_to_str(u->mac, m), r.reason,
                         r.detail, r.version);
                attempt_failed(u, r.reason);
            } else if (u->reason == SIOT_OTA_R_TIMED_OUT &&
                       (u->state == SIOT_OTA_U_FAILED || u->state == SIOT_OTA_U_WAITING)) {
                /* it answered after this board gave up on it: the real reason replaces "timed out" */
                ESP_LOGW(TAG, "%s: late result, reason %u (was timed out)", siot_mac_to_str(u->mac, m), r.reason);
                u->reason = r.reason;
                changed(true);
            }
        }
    } else if (f->msg_type == SAFR_MSG_OTA_STATUS) {
        siot_ota_status_t st;
        if (u != NULL && s_ro.cur == i && siot_ota_status_decode(f->payload, f->payload_len, &st) &&
            st.state >= SIOT_OTA_U_DOWNLOADING && st.state <= SIOT_OTA_U_SELFTEST) {
            u->status_seen = true;
            if (u->acked_ms == 0) u->acked_ms = now_ms(); /* its ACK was lost, its status was not */
            const bool new_state = st.state != u->state;
            u->percent = st.percent;
            if (new_state) {
                set_state(u, st.state, SIOT_OTA_R_NONE);
                changed(false);
            }
        }
    } else if (f->msg_type == SAFR_MSG_ACK && u != NULL && s_ro.cur == i && u->state == SIOT_OTA_U_OFFERED &&
               f->payload_len >= 4 && siot_get_u16(&f->payload[0]) == u->offer_msg_id) {
        if (f->payload[2] == SAFR_ACK_OK) {
            if (u->acked_ms == 0) {
                u->acked_ms = now_ms();
                ESP_LOGI(TAG, "%s: took the offer", siot_mac_to_str(u->mac, m));
            }
        } else {
            attempt_failed(u, f->payload[3] ? f->payload[3] : SIOT_OTA_R_BAD_ARGS);
        }
    }
    xSemaphoreGive(s_lock);
}

/* ---- 4. OTA_CONTROL / GET_ROLLOUT, the tick -------------------------------------------- */

static void offer(unit_t *u)
{
    uint8_t args[SAFR_MAX_PAYLOAD];
    const size_t alen = siot_ota_offer_encode(args, &s_ro.img);
    u->offer_msg_id = siot_coordinator_command_unit(u->mac, SAFR_CMD_OTA_OFFER, args, alen);
    u->last_offer_ms = now_ms();
    u->offer_tries++;
}

static bool passes(const siot_devtab_entry_t *e, const siot_ota_control_t *c)
{
    if (e->state != SIOT_DEV_ONLINE) return false;
    if (e->product == SAFR_PRODUCT_UNKNOWN || (e->product >> 8) != c->family) return false;
    switch (c->filter) {
    case SIOT_OTA_FILTER_ALL:     return true;
    case SIOT_OTA_FILTER_PRODUCT: return e->product == c->product;
    case SIOT_OTA_FILTER_ZONE:    return strcmp(e->zone, c->zone) == 0;
    case SIOT_OTA_FILTER_UNIT:    return siot_mac_eq(e->mac, c->mac);
    default:                      return false;
    }
}

static uint8_t start(const siot_ota_control_t *c)
{
    if (s_ro.state == SIOT_OTA_RO_ROLLING || s_ro.state == SIOT_OTA_RO_PAUSED) return SIOT_OTA_R_BUSY;
    if (c->family != SAFR_FAMILY_NODE && c->family != SAFR_FAMILY_LEAF) return SIOT_OTA_R_BAD_ARGS;
    if (siot_coordinator_alarm_recent()) return SIOT_OTA_R_BUSY_ALARM;
    siot_ota_image_t img = {.family = c->family, .deadline_s = deadline_s(c->family)};
    if (!siot_ota_board_stored(c->family, img.version, &img.size, img.sha256)) return SIOT_OTA_R_BAD_ARGS;
    if (!alloc_units()) return SIOT_OTA_R_NO_SPACE;

    const size_t n = siot_devtab_snapshot(s_snap, SIOT_DEVTAB_CAP, now_ms());
    uint16_t k = 0;
    for (size_t i = 0; i < n; i++) {
        if (!passes(&s_snap[i], c)) continue;
        unit_t *u = &s_ro.u[k++];
        memset(u, 0, sizeof(*u));
        memcpy(u->mac, s_snap[i].mac, 6);
        u->product = s_snap[i].product;
        strlcpy(u->version, s_snap[i].fw, sizeof(u->version));
        set_state(u, SIOT_OTA_U_WAITING, SIOT_OTA_R_NONE);
    }
    if (k == 0) return SIOT_OTA_R_BAD_ARGS; /* nobody online passes the filter */
    if (ota_server_start() != ESP_OK) return SIOT_OTA_R_NO_SPACE;

    s_ro.img = img;
    s_ro.family = c->family;
    s_ro.n = k;
    s_ro.cur = -1;
    s_ro.aborted = false;
    s_ro.state = SIOT_OTA_RO_ROLLING;
    ESP_LOGW(TAG, "rollout of %s %s (%lu B) begins: %u unit(s), filter %u", ota_family_name(c->family),
             img.version, (unsigned long)img.size, k, c->filter);
    return SIOT_OTA_R_NONE;
}

void ota_rollout_on_control(const siot_safr_frame_t *f)
{
    const size_t alen = f->payload_len >= 2 ? f->payload[1] : 0;
    siot_ota_control_t c;
    if (f->payload_len < 2 + alen || !siot_ota_control_decode(&f->payload[2], alen, &c)) {
        siot_coordinator_ack_tablet(f->msg_id, SAFR_ACK_ERROR, SIOT_OTA_R_BAD_ARGS);
        return;
    }
    xSemaphoreTake(s_lock, portMAX_DELAY);
    uint8_t why = SIOT_OTA_R_NONE;
    const bool live = s_ro.state == SIOT_OTA_RO_ROLLING || s_ro.state == SIOT_OTA_RO_PAUSED;
    switch (c.action) {
    case SIOT_OTA_ACT_START:
        why = start(&c);
        break;
    case SIOT_OTA_ACT_PAUSE:
        if (!live || c.family != s_ro.family) why = SIOT_OTA_R_BAD_ARGS;
        else s_ro.state = SIOT_OTA_RO_PAUSED;
        break;
    case SIOT_OTA_ACT_RESUME:
        if (!live || c.family != s_ro.family) why = SIOT_OTA_R_BAD_ARGS;
        else if (siot_coordinator_alarm_recent()) why = SIOT_OTA_R_BUSY_ALARM;
        else { s_ro.state = SIOT_OTA_RO_ROLLING; ota_server_start(); }
        break;
    case SIOT_OTA_ACT_ABORT:
        if (!live || c.family != s_ro.family) { why = SIOT_OTA_R_BAD_ARGS; break; }
        s_ro.aborted = true;
        for (int i = 0; i < s_ro.n; i++) {
            if (s_ro.u[i].state == SIOT_OTA_U_WAITING) set_state(&s_ro.u[i], SIOT_OTA_U_SKIPPED, SIOT_OTA_R_ABORTED);
        }
        finish_if_done(); /* the unit that is downloading finishes first */
        break;
    default:
        why = SIOT_OTA_R_BAD_ARGS;
    }
    /* the ACK first: the tablet that has it then reads the table that follows */
    siot_coordinator_ack_tablet(f->msg_id, why == SIOT_OTA_R_NONE ? SAFR_ACK_OK : SAFR_ACK_ERROR, why);
    if (why == SIOT_OTA_R_NONE) {
        ESP_LOGW(TAG, "tablet: action %u → rollout state %u", c.action, s_ro.state);
        changed(true);
    }
    xSemaphoreGive(s_lock);
}

void ota_rollout_on_get(const siot_safr_frame_t *f)
{
    const uint8_t page = (f->payload_len >= 3 && f->payload[1] >= 1) ? f->payload[2] : 0;
    xSemaphoreTake(s_lock, portMAX_DELAY);
    if (f->flags & SAFR_F_ACK_REQ) siot_coordinator_ack_tablet(f->msg_id, SAFR_ACK_OK, SIOT_OTA_R_NONE);
    send_everything(page);
    xSemaphoreGive(s_lock);
}

/* The next unit: fresh ones before the ones that failed once, the root last. */
static int pick_next(void)
{
    uint8_t root[6];
    const bool has_root = siot_coordinator_root(root);
    int best = -1, best_rank = 99;
    for (int i = 0; i < s_ro.n; i++) {
        const unit_t *u = &s_ro.u[i];
        if (u->state != SIOT_OTA_U_WAITING) continue;
        const int rank = (has_root && siot_mac_eq(u->mac, root) ? 2 : 0) + (u->attempts > 0 ? 1 : 0);
        if (rank < best_rank) { best = i; best_rank = rank; }
    }
    return best;
}

void ota_rollout_tick(int64_t t)
{
    xSemaphoreTake(s_lock, portMAX_DELAY);
    if (s_ro.state != SIOT_OTA_RO_ROLLING && s_ro.state != SIOT_OTA_RO_PAUSED) {
        xSemaphoreGive(s_lock);
        return;
    }
    if (s_ro.state == SIOT_OTA_RO_ROLLING && siot_coordinator_alarm_recent()) {
        ESP_LOGE(TAG, "ALARM on the site: rollout PAUSED, no new offer (§13.1)");
        s_ro.state = SIOT_OTA_RO_PAUSED;
        changed(true);
    }
    if (s_ro.cur >= 0) {
        unit_t *u = &s_ro.u[s_ro.cur];
        if (t - u->offered_ms > (int64_t)deadline_s(s_ro.family) * 1000) {
            attempt_failed(u, SIOT_OTA_R_TIMED_OUT);
        } else if (u->acked_ms == 0 && t - u->last_offer_ms > offer_ack_ms(s_ro.family)) {
            if (u->offer_tries >= OFFER_TRIES) attempt_failed(u, SIOT_OTA_R_TIMED_OUT);
            else offer(u);
        } else if (u->acked_ms != 0 && !u->status_seen && t - u->acked_ms > FIRST_STATUS_MS) {
            char m[SIOT_MAC_STR_LEN];
            ESP_LOGW(TAG, "%s: took the offer and did nothing — a firmware without OTA?",
                     siot_mac_to_str(u->mac, m));
            u->attempts = MAX_ATTEMPTS - 1; /* not offered again in this rollout (§13.4) */
            attempt_failed(u, SIOT_OTA_R_TIMED_OUT);
        }
    } else if (s_ro.state == SIOT_OTA_RO_ROLLING) {
        const int i = pick_next();
        if (i >= 0) {
            unit_t *u = &s_ro.u[i];
            char m[SIOT_MAC_STR_LEN];
            u->offered_ms = t;
            u->acked_ms = 0;
            u->offer_tries = 0;
            u->status_seen = false;
            u->percent = 0;
            set_state(u, SIOT_OTA_U_OFFERED, SIOT_OTA_R_NONE);
            s_ro.cur = i;
            ESP_LOGW(TAG, "%s: offered %s (attempt %u)", siot_mac_to_str(u->mac, m), s_ro.img.version,
                     u->attempts + 1);
            offer(u);
            changed(false);
        } else {
            finish_if_done();
            if (s_ro.state != SIOT_OTA_RO_ROLLING) changed(true);
        }
    }
    if ((s_ro.state == SIOT_OTA_RO_ROLLING || s_ro.state == SIOT_OTA_RO_PAUSED) && t >= s_ro.next_page_ms) {
        send_pages_of_rollout(0);
        s_ro.next_page_ms = t + PAGE_EVERY_MS;
    }
    xSemaphoreGive(s_lock);
}

void ota_rollout_on_stored(uint8_t family)
{
    xSemaphoreTake(s_lock, portMAX_DELAY);
    if (s_ro.family == family && (s_ro.state == SIOT_OTA_RO_DONE || s_ro.state == SIOT_OTA_RO_PARTIAL)) {
        s_ro.state = SIOT_OTA_RO_IDLE; /* that rollout was of another image */
        s_ro.n = 0;
        persist();
    }
    send_staged(family);
    xSemaphoreGive(s_lock);
}

bool ota_rollout_busy(uint8_t family)
{
    xSemaphoreTake(s_lock, portMAX_DELAY);
    const bool busy = s_ro.family == family &&
                      (s_ro.state == SIOT_OTA_RO_ROLLING || s_ro.state == SIOT_OTA_RO_PAUSED);
    xSemaphoreGive(s_lock);
    return busy;
}

esp_err_t ota_rollout_init(void)
{
    if (s_lock == NULL) s_lock = xSemaphoreCreateMutex();
    if (s_lock == NULL) return ESP_ERR_NO_MEM;
    xSemaphoreTake(s_lock, portMAX_DELAY);
    restore();
    xSemaphoreGive(s_lock);
    siot_coordinator_set_ota_uplink_sink(on_uplink, NULL);
    return ESP_OK;
}
