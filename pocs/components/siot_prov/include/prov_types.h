/*
 * Shared types for the setup-network provisioning flow.
 * Contract: pocs/POC-BRIEF.md §4.1 (siot_prov) and §5 (HTTP contract).
 */
#pragma once

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define SIOT_ID_MAX_LEN     31
#define SIOT_POP_MAX_LEN    63
#define SIOT_MODEL_MAX_LEN  31
#define SIOT_SSID_MAX_LEN   31
#define SIOT_PSK_MAX_LEN    31
#define SIOT_NAME_MAX_LEN   32  /* bytes, spec §5: name <= 32 bytes UTF-8 */
#define SIOT_ZONE_MAX_LEN   16  /* bytes, spec §5: zone <= 16 bytes */
#define SIOT_SAFR_PSK_LEN   16

/* idle -> identified -> stored -> joining -> online | failed (POC-BRIEF §5/§9.3) */
typedef enum {
    SIOT_PROV_IDLE = 0,
    SIOT_PROV_IDENTIFIED,
    SIOT_PROV_STORED,
    SIOT_PROV_JOINING,
    SIOT_PROV_ONLINE,
    SIOT_PROV_FAILED,
} siot_prov_state_t;

typedef enum {
    SIOT_ROLE_NODE = 0,
    SIOT_ROLE_BOARD = 1,
} siot_role_t;

/* NVS namespace "siot_fact" — written by tools/make_sticker.py, never at
 * runtime (blueprint §2). */
typedef struct {
    char id[SIOT_ID_MAX_LEN + 1];
    char pop[SIOT_POP_MAX_LEN + 1];
    uint8_t mac[6];
    char model[SIOT_MODEL_MAX_LEN + 1];
} siot_factory_id_t;

/* code_json (POC-BRIEF §5): {system_id, net_ssid, net_psk, safr_psk_hex,
 * channel, mesh_id}, plus the name/zone sent alongside it in /provision.
 * NVS namespace "siot_inst" (blueprint §2). */
typedef struct {
    uint16_t system_id;
    char net_ssid[SIOT_SSID_MAX_LEN + 1];
    char net_psk[SIOT_PSK_MAX_LEN + 1];
    uint8_t safr_psk[SIOT_SAFR_PSK_LEN];
    uint8_t channel;
    uint8_t mesh_id;
    char name[SIOT_NAME_MAX_LEN + 1];
    char zone[SIOT_ZONE_MAX_LEN + 1];
} siot_installation_t;

/* POST /enroll (board only, POC-BRIEF.md §5): the app's [{mac,id,name,zone}]
 * list, kept just as MAC+NAME+ZONE — the "id" field isn't needed by the
 * board's INSTALLATION (0x09) reply (spec §7.10), so it's not stored here. */
#define SIOT_MAX_ENROLLED 8

typedef struct {
    uint8_t mac[6];
    char name[SIOT_NAME_MAX_LEN + 1];
    char zone[SIOT_ZONE_MAX_LEN + 1];
} siot_enrolled_entry_t;

#ifdef __cplusplus
}
#endif
