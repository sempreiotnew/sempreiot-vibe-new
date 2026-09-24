/*
 * Shared in-RAM state for the board's root duties (POC-BRIEF.md §4.2).
 * No flash journal / no persistence in round 1 — everything here is RAM-only
 * and reset on reboot.
 */
#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "prov_types.h"

#ifdef __cplusplus
extern "C" {
#endif

#define BOARD_MAX_CHILDREN   8   /* matches SoftAP max_connection */
#define BOARD_MAX_ENROLLED   8
#define BOARD_JOURNAL_CAP    64  /* RAM ring, spec §8 — flash journal is out of scope round 1 */

typedef struct {
    uint8_t  mac[6];
    bool     used;
    int64_t  last_seen_ms;
} board_child_t;

/* Populated from POST /enroll (board only, POC-BRIEF.md §5). NOTE: as of
 * this writing there is no plumbing from siot_prov's handle_enroll() (which
 * only logs the count, see prov_http.c) into this array — see README.md
 * "Known gap" section. INSTALLATION replies will report ENROLLED_COUNT=0
 * until that's wired up. */
typedef struct {
    uint8_t  mac[6];
    char     name[SIOT_NAME_MAX_LEN + 1];
    char     zone[SIOT_ZONE_MAX_LEN + 1];
    bool     used;
} board_enrolled_t;

typedef struct {
    uint32_t jrn_seq;
    uint8_t  mac[6];
    uint8_t  payload[17]; /* SAFR_EVENT_LEN, spec §7.1 */
} board_journal_entry_t;

/* All board-global state: identity, counters, children/enrolled tables,
 * journal. One instance, owned by board_main.c, passed by pointer to
 * root_duties/installation_msg so nothing here is a hidden global. */
typedef struct {
    uint8_t  mac[6];            /* board's own MAC — SRC_MAC on every frame it originates */
    uint16_t boot_ctr;
    uint32_t msg_ctr;
    uint16_t msg_id;

    siot_installation_t inst;  /* loaded once at boot, read-only after that */

    board_child_t    children[BOARD_MAX_CHILDREN];
    board_enrolled_t enrolled[BOARD_MAX_ENROLLED];

    board_journal_entry_t journal[BOARD_JOURNAL_CAP];
    uint32_t journal_top; /* highest assigned JRN_SEQ, 0 = none */

    int64_t next_heartbeat_ms;
    int64_t next_topology_ms;
} board_state_t;

#ifdef __cplusplus
}
#endif
