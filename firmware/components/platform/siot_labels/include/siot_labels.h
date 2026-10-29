/* siot_labels — the board's zone and endereçamento tables (spec §14.1 / §14.2,
 * v3.8). Board only. Two tables of {id, name} behind the names the tablet shows;
 * the id never reaches a user or a unit. Each table carries a revision that
 * increments on every change so a tablet can tell a stale copy.
 *
 * Persisted in NVS namespace "siot_labels", one blob per kind (key "zone" /
 * "addr"): VER u8 ‖ REV u16 ‖ COUNT u8 ‖ (ID u16 ‖ NAME_LEN u8 ‖ NAME)[COUNT].
 * A blob of another VER is dropped on load (nothing shipped; the tablet
 * restores the tables). Thread-safe (internal mutex). */
#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "esp_err.h"

#include "siot_safr.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Loads both tables. Call once after nvs_flash_init(). */
esp_err_t siot_labels_init(void);

/* Create (unknown id) or rename (known id). `kind` = SAFR_LABEL_*, `id` ≠ 0,
 * `name` 1..SAFR_LABEL_NAME_MAX bytes. ESP_ERR_INVALID_ARG on a bad kind / id /
 * name, ESP_ERR_NO_MEM when the kind holds SAFR_LABEL_CAP labels. A rename to
 * the same name changes nothing (REV unchanged). */
esp_err_t siot_labels_set(uint8_t kind, uint16_t id, const char *name);

/* ESP_ERR_NOT_FOUND when unknown. The caller checks nothing references the id
 * (device table, rules) before calling — spec §7.6 DEL_LABEL `DETAIL 0x08`. */
esp_err_t siot_labels_del(uint8_t kind, uint16_t id);

/* true for id 0 (none) and for every id in the table. */
bool siot_labels_exists(uint8_t kind, uint16_t id);

/* The id of the label of `kind` named exactly `name` (bytes), 0 when none. */
uint16_t siot_labels_find(uint8_t kind, const char *name);

/* The next free id of `kind` (one past the highest), never 0. */
uint16_t siot_labels_next_id(uint8_t kind);

/* Copies up to `max` labels of `kind`, id order; `*rev_out` (may be NULL) =
 * the table's revision. Returns the count. */
size_t siot_labels_snapshot(uint8_t kind, siot_safr_label_t *out, size_t max, uint16_t *rev_out);

/* Erases both tables (factory reset). */
esp_err_t siot_labels_erase_all(void);

#define SIOT_LABELS_NS "siot_labels"

#ifdef __cplusplus
}
#endif
