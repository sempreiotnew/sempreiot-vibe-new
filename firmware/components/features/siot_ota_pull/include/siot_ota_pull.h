/* siot_ota_pull — what a unit does with a firmware offer, shared by the node
 * (siot_ota_node) and the leaf (siot_ota_leaf): pull the image from the board
 * over HTTP into the inactive slot, check it, remember what was installed, and
 * — on the boots that follow — say whether this is the new image's self-test
 * or the old image back after the new one was thrown away (protocol §13.4,
 * §13.5). No mesh, no sleep, no frames: the caller owns those.
 */
#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "esp_err.h"
#include "siot_ota_proto.h"

#ifdef __cplusplus
extern "C" {
#endif

#define SIOT_OTA_PULL_URL "http://192.168.4.1:8070/fw/" /* + "node.bin" / "leaf.bin" (§13.4) */

/* Called with 0, 10, 20 … 100 while the image arrives (the caller sends
 * OTA_STATUS). `abort` is asked between blocks: true = stop now, BUSY_ALARM. */
typedef void (*siot_ota_pull_progress_t)(uint8_t percent, void *ctx);
typedef bool (*siot_ota_pull_abort_t)(void *ctx);

/* Pulls `url`, checks size, SHA-256, project_name (`project`), version and —
 * in esp_ota_end — the signature, then makes the slot the next boot and
 * writes the pending record. SIOT_OTA_R_NONE = installed: restart (node) or
 * sleep (leaf) and the next boot runs it. */
siot_ota_reason_t siot_ota_pull_install(const siot_ota_image_t *img, const char *url, const char *project,
                                        siot_ota_pull_progress_t progress, siot_ota_pull_abort_t abort, void *ctx);

/* ---- the pending record (NVS) and what a boot means -------------------------- */

typedef enum {
    SIOT_OTA_BOOT_PLAIN = 0,   /* nothing to do */
    SIOT_OTA_BOOT_SELFTEST,    /* this is the new image's first boot: test, then confirm or roll back */
    SIOT_OTA_BOOT_REPORT_OK,   /* this is the new image, settled, and its OK was never acknowledged */
    SIOT_OTA_BOOT_ROLLED_BACK, /* the old image: the new one was thrown away — report it */
} siot_ota_boot_kind_t;

typedef struct {
    siot_ota_boot_kind_t kind;
    uint8_t  reason;   /* ROLLED_BACK: SELFTEST_FAIL / NOT_VALIDATED / NOT_BOOTED */
    uint8_t  detail;   /* NOT_VALIDATED: esp_reset_reason() of the reset that ended the new image */
    uint16_t awake_s;  /* what the record kept (leaf: seconds awake for the pull) */
    char     version[SIOT_OTA_VER_MAX_LEN + 1]; /* the image the record names */
} siot_ota_boot_t;

/* Reads the running slot's state and the pending record. */
void siot_ota_pull_boot_state(siot_ota_boot_t *out);

/* The seconds-awake field of the pending record (leaf: set after the pull). */
void siot_ota_pull_pending_set_awake(uint16_t awake_s);

/* Erases the pending record: the board acknowledged the result. */
void siot_ota_pull_pending_clear(void);

#ifdef __cplusplus
}
#endif
