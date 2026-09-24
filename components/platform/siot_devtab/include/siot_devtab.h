/* siot_devtab — the board's device table (docs/others/installation-lifecycle-v1.md §3,
 * spec §7.12). Board only.
 *
 * One entry per MAC. Persisted in NVS namespace "siot_devtab" (key = 12
 * lowercase hex chars of the MAC, blob = siot_devtab_rec_t) only on first
 * sighting and operator actions; `online` / `missing` are derived at run time
 * from `last_seen_ms` and never written. Thread-safe (internal mutex).
 *
 * Who writes what (lifecycle §3.2):
 *   discovery   siot_devtab_touch()      any authenticated frame → SEEN_EVER, online
 *   announce    siot_devtab_announce()   NAME_ANNOUNCE → name/zone unless ANNOTATED
 *   hint        siot_devtab_hint()       /enroll from a phone → `expected`
 *   operator    set_name_zone / retire / unretire / replace / forget / decommission
 */
#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "esp_err.h"
#include "sdkconfig.h"

#include "siot_config.h"

#ifdef __cplusplus
extern "C" {
#endif

#define SIOT_DEVTAB_CAP CONFIG_SIOT_DEVTAB_CAP

/* Entry states on the wire (spec §7.12). */
typedef enum {
    SIOT_DEV_EXPECTED = 0,
    SIOT_DEV_ONLINE   = 1,
    SIOT_DEV_MISSING  = 2,
    SIOT_DEV_RETIRED  = 3,
} siot_dev_state_t;

/* Flags on the wire (spec §7.12). */
#define SIOT_DEV_F_SEEN_EVER            0x01
#define SIOT_DEV_F_ANNOTATED            0x02
#define SIOT_DEV_F_PENDING_RENAME       0x04
#define SIOT_DEV_F_HEARD_WHILE_RETIRED  0x08
#define SIOT_DEV_F_PENDING_DECOMMISSION 0x10

#define SIOT_DEV_ROLE_UNKNOWN 0xFF

typedef struct {
    uint8_t  mac[6];
    uint8_t  role;          /* SAFR_ROLE_* or SIOT_DEV_ROLE_UNKNOWN */
    uint8_t  state;         /* siot_dev_state_t, derived by snapshot(); stored only as expected/retired */
    uint8_t  flags;         /* SIOT_DEV_F_* */
    uint32_t first_seen;    /* epoch s of the first authenticated frame, 0 = never */
    int64_t  last_seen_ms;  /* RAM only; <0 = never this boot */
    char     name[SIOT_NAME_MAX_LEN + 1];
    char     zone[SIOT_ZONE_MAX_LEN + 1];
} siot_devtab_entry_t;

/* Loads every persisted entry into RAM. Call once after nvs_flash_init(). */
esp_err_t siot_devtab_init(void);

size_t siot_devtab_count(void);

/* Copy of one entry with its derived state (see siot_devtab_snapshot). */
bool siot_devtab_get(const uint8_t mac[6], int64_t now_ms, siot_devtab_entry_t *out);

/* Discovery: an authenticated frame from `mac` just arrived. Creates the
 * entry when unknown (if there is room). `role` = SAFR_ROLE_* when the frame
 * says so, else SIOT_DEV_ROLE_UNKNOWN. `epoch_now` = wall clock s or 0.
 * Returns true when the MAC is RETIRED: the caller must drop the frame
 * (HEARD_WHILE_RETIRED is set here). `pending_out` (may be NULL) receives the
 * entry's flags so the caller can push a pending SET_DEVICE / DECOMMISSION. */
bool siot_devtab_touch(const uint8_t mac[6], int64_t now_ms, uint32_t epoch_now,
                       uint8_t role, uint8_t *flags_out);

/* NAME_ANNOUNCE: adopt name/zone unless ANNOTATED; when they equal the
 * pending rename, PENDING_RENAME clears. */
esp_err_t siot_devtab_announce(const uint8_t mac[6], const char *name, const char *zone, uint8_t role);

/* /enroll hint from a phone: creates an `expected` entry (no-op when known). */
esp_err_t siot_devtab_hint(const uint8_t mac[6], const char *name, const char *zone);

/* SET_DEVICE from the tablet: ANNOTATED; PENDING_RENAME unless online now.
 * Unknown MAC → new `expected` entry. ESP_ERR_NO_MEM when the table is full. */
esp_err_t siot_devtab_set_name_zone(const uint8_t mac[6], const char *name, const char *zone,
                                    bool online_now);

/* ESP_ERR_NOT_FOUND when unknown. */
esp_err_t siot_devtab_retire(const uint8_t mac[6], bool pending_decommission);
/* ESP_ERR_NOT_FOUND unknown; ESP_ERR_INVALID_STATE not retired. */
esp_err_t siot_devtab_unretire(const uint8_t mac[6]);
esp_err_t siot_devtab_forget(const uint8_t mac[6]);
/* Copies name/zone old → new (ANNOTATED + PENDING_RENAME on new, created as
 * expected if unknown), retires old. `old_online_out` tells the caller
 * whether to originate a DECOMMISSION. ESP_ERR_NOT_FOUND when old unknown. */
esp_err_t siot_devtab_replace(const uint8_t old_mac[6], const uint8_t new_mac[6], int64_t now_ms,
                              bool *old_online_out);
/* Clears PENDING_RENAME / PENDING_DECOMMISSION after the command went out. */
esp_err_t siot_devtab_clear_flags(const uint8_t mac[6], uint8_t flags);

/* Copies up to `max` entries with `state` derived from `now_ms`
 * (AC / unknown role: missing after 45 s; leaf: after 450 s). Returns count. */
size_t siot_devtab_snapshot(siot_devtab_entry_t *out, size_t max, int64_t now_ms);

/* Erases the namespace (factory reset). */
esp_err_t siot_devtab_erase_all(void);

#define SIOT_DEVTAB_NS "siot_devtab"
#define SIOT_DEVTAB_AC_TIMEOUT_MS   45000   /* 3 × 15 s HEARTBEAT (spec §9.2) */
#define SIOT_DEVTAB_LEAF_TIMEOUT_MS 450000  /* 3 × 150 s, the longest leaf cadence */

#ifdef __cplusplus
}
#endif
