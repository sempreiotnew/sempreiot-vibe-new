/* siot_identity — who this unit is (brief §4.1).
 *
 * `id` + `pop` come from the read-only nvs_factory partition, namespace
 * "siot_fact" (written by tools/make_sticker.py, never at runtime). `mac` is
 * the STA MAC from esp_read_mac (= SRC_MAC of every SAFR frame), `model`
 * comes from CONFIG_SIOT_DEV_MODEL. Sticker QR = {id, mac, pop}.
 *
 * Factory half of pocs/components/siot_prov/prov_store.c, with two changes
 * decided in the brief: the partition is nvs_factory (not nvs) and the
 * Kconfig id/pop fallback is gone — no identity means UNPROVISIONED_FACTORY.
 */
#pragma once

#include <stdbool.h>
#include <stdint.h>

#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

#define SIOT_ID_MAX_LEN     31
#define SIOT_POP_MAX_LEN    63
#define SIOT_POP_MIN_LEN    8   /* WPA2 minimum; the sticker uses 16+ */
#define SIOT_MODEL_MAX_LEN  31

typedef struct {
    char    id[SIOT_ID_MAX_LEN + 1];
    char    pop[SIOT_POP_MAX_LEN + 1];
    char    model[SIOT_MODEL_MAX_LEN + 1];
    uint8_t mac[6];
} siot_identity_t;

/* Reads mac + model always, then id/pop from nvs_factory.
 *   ESP_OK              identity complete
 *   ESP_ERR_NOT_FOUND   partition, namespace or keys missing / pop too short
 *   other               NVS error
 * After any return siot_identity_get() is usable (id/pop empty on failure). */
esp_err_t siot_identity_init(void);

const siot_identity_t *siot_identity_get(void);

/* true when id and pop were read (unit may be provisioned). */
bool siot_identity_valid(void);

#ifdef __cplusplus
}
#endif
