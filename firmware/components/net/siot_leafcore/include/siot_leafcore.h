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
#include <stddef.h>
#include <stdint.h>

#include "siot_ota_proto.h"

#ifdef __cplusplus
extern "C" {
#endif

void siot_leafcore_run(bool has_code) __attribute__((noreturn));

/* ---- firmware update (protocol §13.5) — the feature above this layer ------
 * siot_ota_leaf plugs in here; the leaf app wires it. Every hook is optional. */
typedef struct {
    /* This boot is a new image's first: the heartbeat's parent ACK is its self-test. */
    bool (*selftest_pending)(void);
    /* The verdict of that wake (may roll back and reboot: does not return then). */
    void (*selftest_verdict)(bool parent_heard);
    /* A result the board has not acknowledged yet: this wake needs a parent. */
    bool (*report_due)(void);
    /* ... and say it (once per wake with a parent). */
    void (*report_if_due)(void);
    /* The parent's ACK carried an offer: answer it; true = an image was installed. */
    bool (*on_offer)(uint16_t offer_msg_id, const siot_ota_image_t *img, bool alarm_wake,
                     const uint8_t parent_mac[6], int64_t wake_started_ms);
} siot_leafcore_ota_t;

void siot_leafcore_set_ota(const siot_leafcore_ota_t *hooks);

/* For the feature: frames to the parent, during a wake only. */
bool siot_leafcore_send_acked(uint8_t msg_type, const uint8_t *payload, size_t len, uint32_t wait_ms);
void siot_leafcore_send(uint8_t msg_type, const uint8_t *payload, size_t len);

#ifdef __cplusplus
}
#endif
