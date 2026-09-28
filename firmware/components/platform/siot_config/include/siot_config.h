/* siot_config — what provisioning wrote and what must survive a reboot
 * (brief §4.2). NVS namespace "siot_inst" in the ordinary "nvs" partition.
 *
 * | key        | type | notes                                                    |
 * | code       | blob | siot_installation_t, exactly as /provision delivered it  |
 * | enrolled_n | u8   | board only: entries in `enrolled`                        |
 * | enrolled   | blob | siot_enrolled_entry_t[enrolled_n]                        |
 * | boot_ctr   | u16  | ++ on every boot (spec §3/§4) — POC randomised it        |
 * | dev_seq    | u16  | last EVENT sequence (spec §6) — POC started random        |
 *
 * Installation half of pocs/components/siot_prov/prov_store.c + prov_types.h.
 * Nothing is derived from the code on the device (blueprint §0).
 * Factory reset = erase this namespace, keep nvs_factory.
 */
#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

#define SIOT_SSID_MAX_LEN   31
#define SIOT_PSK_MAX_LEN    31
#define SIOT_NAME_MAX_LEN   32  /* bytes, brief §7: name <= 32 bytes UTF-8 */
#define SIOT_ZONE_MAX_LEN   16  /* bytes, brief §7: zone <= 16 bytes */
#define SIOT_SAFR_PSK_LEN   16
#define SIOT_MAX_ENROLLED   8

/* The code (blueprint §0) + the name/zone sent alongside it in /provision. */
typedef struct {
    uint16_t system_id;
    char     net_ssid[SIOT_SSID_MAX_LEN + 1];
    char     net_psk[SIOT_PSK_MAX_LEN + 1];
    uint8_t  safr_psk[SIOT_SAFR_PSK_LEN];
    uint8_t  channel;
    uint8_t  mesh_id;
    char     name[SIOT_NAME_MAX_LEN + 1];
    char     zone[SIOT_ZONE_MAX_LEN + 1];
} siot_installation_t;

/* POST /enroll (board only): the app's list, kept as MAC + NAME + ZONE. */
typedef struct {
    uint8_t mac[6];
    char    name[SIOT_NAME_MAX_LEN + 1];
    char    zone[SIOT_ZONE_MAX_LEN + 1];
} siot_enrolled_entry_t;

/* Loads the code (if any) into RAM and increments + persists boot_ctr.
 * Call once per boot, after nvs_flash_init(). */
esp_err_t siot_config_init(void);

/* true when a code exists (unit is provisioned). */
bool siot_config_has_code(void);

/* The stored code; all-zero when siot_config_has_code() is false. */
const siot_installation_t *siot_config_code(void);

esp_err_t siot_config_save_code(const siot_installation_t *inst);

esp_err_t siot_config_save_enrolled(const siot_enrolled_entry_t *list, size_t count);

/* Fills `out` (capacity `max_count`); returns how many were loaded. */
size_t siot_config_load_enrolled(siot_enrolled_entry_t *out, size_t max_count);

/* This boot's BOOT_CTR (already incremented by siot_config_init). Never 0
 * and never 1 (1 is reserved for the Appendix A vectors, brief §8). */
uint16_t siot_config_boot_ctr(void);

/* Last DEV_SEQ issued (0 = none yet). */
uint16_t siot_config_dev_seq(void);

/* Allocates the next DEV_SEQ for a distinct EVENT and persists it
 * (spec §6: wraps 0xFFFF → 1, 0 reserved). */
uint16_t siot_config_dev_seq_next(void);

/* Erases "siot_inst" (code, enrolled, counters). nvs_factory is untouched.
 * The caller reboots. */
esp_err_t siot_config_factory_reset(void);

#ifdef __cplusplus
}
#endif
