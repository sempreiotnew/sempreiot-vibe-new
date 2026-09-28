/* siot_leafcore — the battery leaf runtime (protocol §12, v3.4).
 *
 *   siot_leafcore_run(has_code)   never returns in DEEP mode: it ends every
 *                                 wake in esp_deep_sleep_start(); in LIGHT /
 *                                 NONE it loops for ever.
 *
 * Wake cycle (§12.2): outbox drain → HEARTBEAT (unicast, F_ACK_REQ) → parent
 * ACK ≤ 100 ms (EPOCH, CHANNEL, PENDING, NO_PATH) → mailbox drain → sleep,
 * 500 ms budget. Discovery §12.3, button verdict §12.8, setup window §12.9.
 * State is RTC memory; the outbox is mirrored to NVS ("siot_leaf").
 *
 * Bench notes (phase2-leaf-brief.md §3): log on UART0 (native USB drops on
 * every sleep); `awake_ms` per wake is the battery proxy; the chirp is a log
 * line until a sounder exists.
 */
#pragma once

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

void siot_leafcore_run(bool has_code) __attribute__((noreturn));

#ifdef __cplusplus
}
#endif
