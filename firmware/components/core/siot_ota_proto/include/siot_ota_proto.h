/* siot_ota_proto — firmware update on the wire (protocol §13, v3.5).
 *
 * Every layout here is the one written in docs/safr/protocol-safr-v3.md §13;
 * change the document first. Integers are big-endian, strings carry a length
 * byte and no terminator, a version is ASCII semver of at most
 * SIOT_OTA_VER_MAX_LEN bytes. Encoders return the bytes written (the buffer
 * must hold SAFR_MAX_PAYLOAD); decoders return false on a short, long or
 * out-of-range payload and leave the output undefined.
 */
#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "siot_safr.h"

#ifdef __cplusplus
extern "C" {
#endif

#define SIOT_OTA_VER_MAX_LEN SAFR_FW_MAX_LEN
#define SIOT_OTA_SHA_LEN     32
/* OTA_OFFER args at their longest: FAMILY ‖ SIZE ‖ SHA256 ‖ DEADLINE_S ‖ FLAGS ‖ VER_LEN ‖ VERSION */
#define SIOT_OTA_OFFER_MAX_LEN (1 + 4 + SIOT_OTA_SHA_LEN + 2 + 1 + 1 + SIOT_OTA_VER_MAX_LEN)
#define SIOT_OTA_CHUNK_MAX   4096
#define SIOT_OTA_ZONE_MAX    16

/* FLAGS of OTA_PUSH_BEGIN / OTA_OFFER */
#define SIOT_OTA_F_FORCE 0x01 /* install whatever the version: bench builds only (§13.2) */

/* REASON (§13.7) — one list for every OTA message */
typedef enum {
    SIOT_OTA_R_NONE          = 0,
    SIOT_OTA_R_NOT_NEWER     = 1,  /* offered version <= running */
    SIOT_OTA_R_BUSY_ALARM    = 2,  /* alarm or trouble on the unit / the site */
    SIOT_OTA_R_LOW_BATTERY   = 3,
    SIOT_OTA_R_SIG_FAIL      = 4,  /* not signed by the key the unit trusts */
    SIOT_OTA_R_SHA_FAIL      = 5,
    SIOT_OTA_R_WRONG_FAMILY  = 6,  /* project_name is another image's */
    SIOT_OTA_R_NO_SPACE      = 7,
    SIOT_OTA_R_HTTP_ERR      = 8,
    SIOT_OTA_R_SELFTEST_FAIL = 9,  /* the new image rolled back */
    SIOT_OTA_R_TIMED_OUT     = 10, /* deadline_s passed */
    SIOT_OTA_R_ABORTED       = 11,
    SIOT_OTA_R_BAD_ARGS      = 12,
    SIOT_OTA_R_BUSY          = 13, /* another transfer / rollout is running */
    SIOT_OTA_R_BAD_CRC       = 14, /* chunk: send it again */
    SIOT_OTA_R_OUT_OF_ORDER  = 15, /* chunk: NEXT_SEQ says where to resume */
    SIOT_OTA_R_BAD_VERSION   = 16, /* not a version this rule can compare */
    SIOT_OTA_R_FORCE_REFUSED = 17, /* FORCE on a production build */
    SIOT_OTA_R_NOT_VALIDATED = 18, /* the new image started but was reset before its self-test ended */
    SIOT_OTA_R_NOT_BOOTED    = 19, /* installed, but the bootloader never ran it */
} siot_ota_reason_t;

/* A unit's STATE in OTA_STATUS and in a rollout entry */
typedef enum {
    SIOT_OTA_U_WAITING = 0, SIOT_OTA_U_OFFERED, SIOT_OTA_U_DOWNLOADING, SIOT_OTA_U_VERIFYING,
    SIOT_OTA_U_REBOOTING, SIOT_OTA_U_SELFTEST, SIOT_OTA_U_DONE, SIOT_OTA_U_FAILED, SIOT_OTA_U_SKIPPED,
    SIOT_OTA_U__COUNT
} siot_ota_unit_state_t;

/* The rollout's STATE (OTA blueprint §3.4) */
typedef enum {
    SIOT_OTA_RO_IDLE = 0, SIOT_OTA_RO_STAGED, SIOT_OTA_RO_ROLLING, SIOT_OTA_RO_PAUSED,
    SIOT_OTA_RO_DONE, SIOT_OTA_RO_PARTIAL,
    SIOT_OTA_RO__COUNT
} siot_ota_rollout_state_t;

typedef enum { SIOT_OTA_PUSH_RECEIVING = 0, SIOT_OTA_PUSH_OK = 1, SIOT_OTA_PUSH_FAILED = 2 } siot_ota_push_phase_t;
typedef enum { SIOT_OTA_ACT_START = 1, SIOT_OTA_ACT_PAUSE, SIOT_OTA_ACT_RESUME, SIOT_OTA_ACT_ABORT } siot_ota_action_t;
typedef enum { SIOT_OTA_FILTER_ALL = 0, SIOT_OTA_FILTER_PRODUCT, SIOT_OTA_FILTER_ZONE, SIOT_OTA_FILTER_UNIT } siot_ota_filter_t;

/* ---- the image an OTA_PUSH_BEGIN announces and an OTA_OFFER offers ---------- */

typedef struct {
    uint8_t  family;                 /* SAFR_FAMILY_* */
    uint32_t size;                   /* the signed .bin, bytes */
    uint8_t  sha256[SIOT_OTA_SHA_LEN];
    uint8_t  flags;                  /* SIOT_OTA_F_* */
    char     version[SIOT_OTA_VER_MAX_LEN + 1];
    uint16_t chunk;                  /* OTA_PUSH_BEGIN: bytes per chunk, 1..SIOT_OTA_CHUNK_MAX */
    uint16_t deadline_s;             /* OTA_OFFER: UPDATING instead of missing for this long */
} siot_ota_image_t;

size_t siot_ota_push_begin_encode(uint8_t *p, const siot_ota_image_t *img);
bool   siot_ota_push_begin_decode(const uint8_t *p, size_t len, siot_ota_image_t *img);

/* OTA_OFFER travels as COMMAND 0x1B: these are its ARGS. */
size_t siot_ota_offer_encode(uint8_t *p, const siot_ota_image_t *img);
bool   siot_ota_offer_decode(const uint8_t *p, size_t len, siot_ota_image_t *img);

/* ---- OTA_PUSH_CHUNK: 10 authenticated bytes, then `len` raw bytes on the wire */

#define SIOT_OTA_CHUNK_HDR_LEN 10
typedef struct { uint32_t seq; uint16_t len; uint32_t crc32; } siot_ota_chunk_t;

size_t siot_ota_chunk_encode(uint8_t *p, const siot_ota_chunk_t *c);
bool   siot_ota_chunk_decode(const uint8_t *p, size_t len, siot_ota_chunk_t *c);

/* ---- OTA_PUSH_RESULT (board → tablet) ---------------------------------------- */

typedef struct {
    uint8_t  phase;                  /* siot_ota_push_phase_t */
    uint8_t  reason;                 /* siot_ota_reason_t */
    uint8_t  family;
    uint32_t next_seq;               /* the chunk the board wants next (resume) */
    char     version[SIOT_OTA_VER_MAX_LEN + 1];
} siot_ota_push_result_t;

size_t siot_ota_push_result_encode(uint8_t *p, const siot_ota_push_result_t *r);
bool   siot_ota_push_result_decode(const uint8_t *p, size_t len, siot_ota_push_result_t *r);

/* ---- OTA_STATUS / OTA_RESULT (unit → board) ----------------------------------- */

typedef struct { uint8_t state; uint8_t percent; } siot_ota_status_t;
#define SIOT_OTA_STATUS_LEN 2
size_t siot_ota_status_encode(uint8_t *p, const siot_ota_status_t *s);
bool   siot_ota_status_decode(const uint8_t *p, size_t len, siot_ota_status_t *s);

typedef struct {
    bool     ok;
    uint8_t  reason;
    uint16_t awake_s;                /* battery unit: seconds awake for this update, else 0 */
    char     version[SIOT_OTA_VER_MAX_LEN + 1]; /* what the unit runs NOW */
    uint8_t  detail;                 /* optional trailing byte: with NOT_VALIDATED, the chip's reset
                                        reason (esp_reset_reason_t) that ended the new image; else 0 */
} siot_ota_result_t;

size_t siot_ota_result_encode(uint8_t *p, const siot_ota_result_t *r);
bool   siot_ota_result_decode(const uint8_t *p, size_t len, siot_ota_result_t *r);

/* ---- OTA_CONTROL (COMMAND 0x1D args, tablet → board) --------------------------- */

typedef struct {
    uint8_t  action;                 /* siot_ota_action_t */
    uint8_t  family;                 /* which staged image */
    uint8_t  filter;                 /* siot_ota_filter_t */
    uint16_t product;                /* FILTER_PRODUCT */
    char     zone[SIOT_OTA_ZONE_MAX + 1]; /* FILTER_ZONE */
    uint8_t  mac[6];                 /* FILTER_UNIT */
} siot_ota_control_t;

size_t siot_ota_control_encode(uint8_t *p, const siot_ota_control_t *c);
bool   siot_ota_control_decode(const uint8_t *p, size_t len, siot_ota_control_t *c);

/* ---- OTA_ROLLOUT (board → tablet, paged like DEVICE_TABLE) ---------------------- */

typedef struct {
    uint8_t  page, page_count;       /* 1-based */
    uint16_t total;                  /* units in the rollout */
    uint8_t  count;                  /* entries in this page */
    uint8_t  state;                  /* siot_ota_rollout_state_t */
    uint8_t  family;
    char     target[SIOT_OTA_VER_MAX_LEN + 1];
} siot_ota_rollout_hdr_t;

typedef struct {
    uint8_t  mac[6];
    uint16_t product;
    uint8_t  state;                  /* siot_ota_unit_state_t */
    uint8_t  percent;
    uint8_t  attempts;
    uint8_t  reason;
    uint16_t age_s;                  /* since the last change, 0xFFFF = never */
    char     version[SIOT_OTA_VER_MAX_LEN + 1]; /* what the unit runs now */
} siot_ota_rollout_entry_t;

/* The header's COUNT is written as hdr->count; an encoder of a page writes the
 * header, then entries while siot_ota_rollout_entry_len() still fits. */
size_t siot_ota_rollout_hdr_encode(uint8_t *p, const siot_ota_rollout_hdr_t *h);
size_t siot_ota_rollout_hdr_decode(const uint8_t *p, size_t len, siot_ota_rollout_hdr_t *h); /* bytes used, 0 = bad */
size_t siot_ota_rollout_entry_len(const siot_ota_rollout_entry_t *e);
size_t siot_ota_rollout_entry_encode(uint8_t *p, const siot_ota_rollout_entry_t *e);
size_t siot_ota_rollout_entry_decode(const uint8_t *p, size_t len, siot_ota_rollout_entry_t *e); /* bytes used, 0 = bad */

/* ---- the version rule (§13.2) ---------------------------------------------------- */

typedef struct {
    uint32_t major, minor, patch;
    char     pre[SIOT_OTA_VER_MAX_LEN + 1]; /* "" = a release; "dev", "rc.1", … */
} siot_ota_version_t;

/* "MAJOR.MINOR.PATCH" with an optional "-PRERELEASE"; build metadata after
 * '+' is dropped. false = not a version. */
bool siot_ota_version_parse(const char *s, siot_ota_version_t *out);

/* < 0, 0, > 0. A pre-release is older than its release (0.2.0-dev < 0.2.0);
 * two pre-releases of the same number compare as text. */
int siot_ota_version_cmp(const siot_ota_version_t *a, const siot_ota_version_t *b);

/* May a unit running `running` install `offered`? SIOT_OTA_R_NONE = yes.
 * `force` (the offer's FLAGS) is honoured only when `force_allowed` (a bench
 * build); on a production build it is SIOT_OTA_R_FORCE_REFUSED. */
siot_ota_reason_t siot_ota_accept_version(const char *running, const char *offered, bool force,
                                          bool force_allowed);

/* CRC-32 (IEEE 802.3, reflected, init and final XOR 0xFFFFFFFF) of a chunk's
 * raw bytes: crc32("123456789") == 0xCBF43926. */
uint32_t siot_ota_crc32(const uint8_t *data, size_t len);

#ifdef __cplusplus
}
#endif
