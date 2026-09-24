/*
 * NVS storage for the factory identity (siot_fact) and the installation
 * code (siot_inst). Blueprint §2 / POC-BRIEF §4.1.
 */
#pragma once

#include <stdbool.h>
#include <stddef.h>

#include "esp_err.h"
#include "prov_types.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Loads {id, pop, mac, model} from NVS "siot_fact".
 *
 * INTERIM BEHAVIOUR (flag for the firmware session, see README.md): the
 * factory partition/make_sticker.py flow doesn't exist yet in this repo, so
 * when "siot_fact" has no id/pop this falls back to the Kconfig defaults
 * (menuconfig "SIOT Provisioning (autoconnect POC)") purely to unblock this
 * POC. Production firmware must never synthesize an id/pop at runtime
 * (blueprint §2) — remove this fallback once the factory NVS partition is
 * wired up.
 */
esp_err_t siot_store_load_factory(siot_factory_id_t *out);

/* NULL/false when "siot_inst" is empty (unprovisioned — enter setup mode). */
bool siot_store_load_installation(siot_installation_t *out);

esp_err_t siot_store_save_installation(const siot_installation_t *inst);

esp_err_t siot_store_erase_installation(void);

/* Board-only: the parsed POST /enroll list (POC-BRIEF §5), persisted under
 * "siot_inst" alongside the installation code so it survives the reboot into
 * normal mode regardless of whether /enroll lands before or after /provision.
 * `count` is capped to SIOT_MAX_ENROLLED by the caller (prov_http.c). */
esp_err_t siot_store_save_enrolled(const siot_enrolled_entry_t *list, size_t count);

/* Fills `out` (capacity `max_count`) and returns how many were loaded (0 if
 * "siot_inst" has no enrolled blob yet). */
size_t siot_store_load_enrolled(siot_enrolled_entry_t *out, size_t max_count);

#ifdef __cplusplus
}
#endif
