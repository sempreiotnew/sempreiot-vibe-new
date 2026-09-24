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
 *   ONLINE, board          magenta flash 250 ms every 5 s (board)
 *   ONLINE, node level 1   green flash 250 ms every 5 s (root)
 *   ONLINE, node level ≥ 2 off (child)
 *   DEGRADED               keeps the role colour (no pattern defined yet)
 *   ALARM_SET              red solid until ALARM_CLEARED
 *   IDENTIFY               blue blink, 1 s period, for N s (default 3)
 *   SURVEY_HEARD           passive unit: 1 s solid in the colour of the RSSI it
 *                          heard the probe at (green ≥ −75, yellow ≥ −85, red)
 *   SURVEY_ANSWER          emitter: one 400 ms pulse per answering unit, colour
 *                          of that link's RSSI; SURVEY_RESULT with count 0 =
 *                          one red pulse (lifecycle §6 range test)
 *
 * Traffic (decided 2026-09-23, docs/sempreiot-system-reference.md §3.7 row
 * 7.7) — pulses only when THIS unit transmits (SIOT_EVT_SAFR_TX: its own
 * frames and, on the board, relays); nothing on receive:
 *
 *   background tick        blue 100 ms   HEARTBEAT, TOPOLOGY, NAME_ANNOUNCE,
 *                                        EVENT_LOG_*, INSTALLATION
 *   message                blue 500 ms   EVENT, ACK, COMMAND, TIME_SYNC
 *   own event confirmed    cyan 500 ms   SIOT_EVT_ACK_RECEIVED — the tablet's
 *                                        ACK for a frame this unit sent
 *
 * Pulses queue in arrival order instead of overriding each other, so a tap
 * reads as "blue, then cyan" (EVENT out, ACK back) and a lost ACK as three
 * blues 2 s apart. Ticks fold into a running tick; IDENTIFY suppresses
 * traffic pulses while it runs. The role colour is off during a pulse.
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
    SIOT_LED_WHITE_SOLID,     /* factory-reset armed (button held); console */
    SIOT_LED_GREEN_BLINK,     /* root node: 250 ms flash every 5 s */
    SIOT_LED_GREEN_SOLID,     /* installed cue (blueprint, not wired) */
    SIOT_LED_MAGENTA_SOLID,   /* (console only) */
    SIOT_LED_MAGENTA_BLINK,   /* board serving: 250 ms flash every 5 s */
    SIOT_LED_RED_SOLID,       /* alarm / fault */
    SIOT_LED_RED_BLINK,       /* unprovisioned factory: 250 ms every 5 s */
    SIOT_LED_BLUE_BLINK,      /* IDENTIFY (1 s period) */
    SIOT_LED_BLUE_SOLID,      /* pulse: background tick / outgoing message */
    SIOT_LED_CYAN_SOLID,      /* pulse: own event confirmed by the tablet */
    SIOT_LED_YELLOW_SOLID,    /* survey: only weak answers (lifecycle §6) */
    SIOT_LED_WHITE_BREATHE,   /* configured, finding the network: slow dim fade, never a blink */
} siot_led_pattern_t;

#define SIOT_LED_SURVEY_HEARD_MS  1000  /* passive unit: solid colour of the probe it heard */
#define SIOT_LED_SURVEY_ANSWER_MS  400  /* emitter: one pulse per unit that answered */
#define SIOT_LED_SURVEY_GOOD_DBM   (-75) /* green at or above */
#define SIOT_LED_SURVEY_WEAK_DBM   (-85) /* yellow at or above, red below */

#define SIOT_LED_TICK_MS            100  /* background traffic */
#define SIOT_LED_MSG_MS             500  /* EVENT / ACK / COMMAND / TIME_SYNC */
#define SIOT_LED_IDENTIFY_DEFAULT_S 3
#define SIOT_LED_PULSE_QUEUE        8

/* Pins from siot_board_def (select it first), LEDC via siot_hal_pwm, 50 ms
 * esp_timer tick, bus subscriptions. `is_board` picks magenta for ONLINE. */
esp_err_t siot_ui_led_init(bool is_board);

/* duration_ms == 0: steady pattern until the next call (remembered as base).
 * duration_ms  > 0: transient shown at once; queued pulses are dropped and
 *                   the base pattern resumes afterwards (IDENTIFY, console). */
void siot_ui_led_set(siot_led_pattern_t pattern, uint32_t duration_ms);

siot_led_pattern_t siot_ui_led_get_base(void);

/* Queues one traffic pulse behind whatever pulse is running (dropped while
 * IDENTIFY runs or when the queue is full). `fold` merges it into an
 * identical pulse already running or last in the queue (ticks). */
void siot_ui_led_pulse(siot_led_pattern_t pattern, uint32_t duration_ms, bool fold);

/* One background tick (blue 100 ms, folded). Kept for the console. */
void siot_ui_led_comm_blink(void);

#ifdef __cplusplus
}
#endif
