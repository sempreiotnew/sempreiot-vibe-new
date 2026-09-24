/*
 * SAFR emitter + downlink dispatch for the AC node -- POC-BRIEF.md §4.3.
 * Payload encoding style ported from mocked-device/main/mesh_sim.c
 * (put_u16/put_u32, event/heartbeat/topology builders, the ACK/retry
 * pattern) -- this is the real-hardware equivalent of one of its simulated
 * nodes, driven by real Mesh-Lite level/parent/children instead of a fake
 * topology table.
 */
#pragma once

#include "prov_types.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Starts the emitter task (HEARTBEAT/TOPOLOGY/NAME_ANNOUNCE on schedule,
 * alarm re-announce, fast-retry) and registers this module as node_mesh's
 * downlink handler. Call after node_mesh_start() and safr_frame_init(). */
void node_safr_start(const siot_installation_t *inst);

/* Wire these into node_button_start(). */
void node_safr_on_short_press(void);  /* EVENT ALERT MANUAL_TEST */
void node_safr_on_double_press(void); /* EVENT ALARM SMOKE_ALARM, spec §7.2 */

#ifdef __cplusplus
}
#endif
