#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "siot_config.h"
#include "siot_devtab.h"

/* INSTALLATION payload (spec §7.10): SYSTEM_ID, CHANNEL, NET_SSID, NAME,
 * ENROLLED {MAC, NAME, ZONE}[m] from the first device-table entries that fit.
 * Never net_psk / safr_psk. `out` >= SAFR_MAX_PAYLOAD. Legacy view for
 * pre-v3.2 tablets. */
size_t coord_installation_encode(const siot_installation_t *code,
                                 const siot_devtab_entry_t *entries, size_t n,
                                 uint8_t *out);

/* DEVICE_TABLE (spec §7.12): encodes page `page` (1-based) of `entries` into
 * `out` (>= SAFR_MAX_PAYLOAD), filling each page up to the payload cap.
 * `*page_count_out` = pages needed for `n` entries. Returns the payload
 * length, 0 when `page` is past the end (page 1 of an empty table is valid). */
size_t coord_devtable_encode_page(const siot_devtab_entry_t *entries, size_t n, int64_t now_ms,
                                  uint8_t page, uint8_t *page_count_out, uint8_t *out);

/* Setup channel (coord_setup.c): a serial frame that is not on the
 * installation key. Returns true when it was a setup-channel frame (handled
 * or rejected), false when it is simply foreign. */
bool coord_setup_handle(const uint8_t *frame, size_t len, bool provisioned);

/* Admin window (coord_admin.c, lifecycle §11). */
esp_err_t coord_admin_init(void);
void coord_admin_note_alarm(void);
