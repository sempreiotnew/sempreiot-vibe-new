/* siot_ui_led — the bench LED language (brief §9 table, pocs/README.md),
 * ported from pocs/components/siot_led (pattern engine + 50 ms tick).
 *
 * What is new: the LED follows the event bus. After siot_ui_led_init() nobody
 * needs to call siot_ui_led_set() for the normal states — netcore /
 * coordinator / provisioning post SIOT_EVT_STATE_CHANGED, MESH_LEVEL,
 * IDENTIFY, ALARM_SET/CLEARED, SAFR_TX/RX and the LED reacts:
 *
 *   UNPROVISIONED_FACTORY  red slow blink        (brief §3: no id/pop)
 *   SETUP                  white blink
 *   JOINING / OFFLINE      white solid
 *   ONLINE, board          magenta solid
 *   ONLINE, node level 1   green flash 250 ms every 5 s (root)
 *   ONLINE, node level ≥ 2 off (child)
 *   DEGRADED               keeps the role colour (no pattern defined yet)
 *   ALARM_SET              red solid until ALARM_CLEARED
 *   IDENTIFY               blue blink, 1 s period, for N s (default 3)
 *   SAFR_TX / SAFR_RX      one blue pulse of 150 ms
 *
 * siot_ui_led_set() remains for tests and the console `led` command.
 */
#pragma once

#include <stdbool.h>
#include <stdint.h>

#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    SIOT_LED_OFF = 0,
    SIOT_LED_WHITE_BLINK,     /* setup mode */
    SIOT_LED_WHITE_SOLID,     /* finding the network */
    SIOT_LED_GREEN_BLINK,     /* root node: 250 ms flash every 5 s */
    SIOT_LED_GREEN_SOLID,     /* installed cue (blueprint, not wired) */
    SIOT_LED_MAGENTA_SOLID,   /* board serving */
    SIOT_LED_RED_SOLID,       /* alarm / fault */
    SIOT_LED_RED_BLINK,       /* unprovisioned factory: 250 ms every 5 s */
    SIOT_LED_BLUE_BLINK,      /* IDENTIFY (1 s period) */
    SIOT_LED_BLUE_SOLID,      /* one-shot pulse: message traffic */
} siot_led_pattern_t;

#define SIOT_LED_COMM_BLINK_MS      150
#define SIOT_LED_IDENTIFY_DEFAULT_S 3

/* Pins from siot_board_def (select it first), LEDC via siot_hal_pwm, 50 ms
 * esp_timer tick, bus subscriptions. `is_board` picks magenta for ONLINE. */
esp_err_t siot_ui_led_init(bool is_board);

/* duration_ms == 0: steady pattern until the next call (remembered as base).
 * duration_ms  > 0: transient; reverts to the base pattern afterwards. */
void siot_ui_led_set(siot_led_pattern_t pattern, uint32_t duration_ms);

siot_led_pattern_t siot_ui_led_get_base(void);

/* One blue pulse per frame; pulses landing while one is lit are folded in. */
void siot_ui_led_comm_blink(void);

#ifdef __cplusplus
}
#endif
