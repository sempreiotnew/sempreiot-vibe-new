/* siot_ota_leaf — a battery unit takes a firmware offer (protocol §13.5, OTA
 * brief step 4). The offer rides the parent's HEARTBEAT ACK; on that wake the
 * leaf answers it and, when taken, pulls the image as a Wi-Fi station on its
 * parent's SoftAP, installs it and sleeps; the next wake is the new image's
 * self-test (one wake: the bootloader gives an unverified image one boot).
 *
 * siot_leafcore owns the wake, the radio and the frames; it calls these at
 * the points §13.5 names. Leaf image only.
 */
#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "esp_err.h"
#include "siot_leaf_proto.h"
#include "siot_ota_proto.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    /* Sends an ACK-required frame to the parent and waits for its hop ACK (§12.6). */
    bool (*send_acked)(uint8_t msg_type, const uint8_t *payload, size_t len, uint32_t wait_ms);
    /* Sends a frame nobody acknowledges (OTA_STATUS, the offer's ACK). */
    void (*send)(uint8_t msg_type, const uint8_t *payload, size_t len);
    uint8_t (*battery_pct)(void);
    /* Installation credentials for the pull: the mesh SSID / PSK (§13.5). */
    const char *net_ssid;
    const char *net_psk;
} siot_ota_leaf_ops_t;

/* Once per boot, before the first frame: reads what this boot means. */
esp_err_t siot_ota_leaf_init(const siot_ota_leaf_ops_t *ops);

/* This boot is the new image's first: the heartbeat's parent ACK is its self-test. */
bool siot_ota_leaf_selftest_pending(void);

/* The verdict of that wake. `parent_heard`: the heartbeat was acknowledged.
 * Passed → the image is confirmed and OTA_RESULT OK goes to the parent.
 * Failed → rollback and reboot (does not return). */
void siot_ota_leaf_selftest_verdict(bool parent_heard);

/* The old image after a rollback, or a result never acknowledged: this wake
 * needs a parent ... */
bool siot_ota_leaf_report_due(void);
/* ... to say it (hop ACK closes it). Call once per wake with a parent. */
void siot_ota_leaf_report_if_due(void);

/* The parent's HEARTBEAT ACK carried an offer (§13.5): answer it and, when
 * taken, pull and install the image right now. `alarm_wake`: a sensor /
 * alarm wake refuses. `wake_started_ms`: to report the seconds awake. Returns
 * true when an image was installed (the caller sleeps; the next wake runs it). */
bool siot_ota_leaf_on_offer(uint16_t offer_msg_id, const siot_ota_image_t *img, bool alarm_wake,
                            const uint8_t parent_mac[6], int64_t wake_started_ms);

#ifdef __cplusplus
}
#endif
