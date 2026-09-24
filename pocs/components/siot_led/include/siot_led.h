/*
 * RGB LED pattern engine -- bench LED language for the POC (Talles,
 * 2026-09-18; supersedes the "colours not final" proposal in
 * docs/others/system-blueprint-v1.md §2):
 *
 *   white blink         = setup mode (waiting for provisioning)
 *   white solid         = node finding the network (not joined yet)
 *   green blink (every 5 s) = ROOT node (level 1, the one bridging to the board)
 *   off                 = NODE (child, level >= 2) joined under a root
 *   magenta solid       = board ("router" of the mesh) up and serving
 *   blue single blink   = one message sent or received (role colour off
 *                         during the blink)
 *   blue blink          = IDENTIFY command
 *   red                 = alarm / fault
 *
 * Ported from the LEDC (PWM) RGB engine in pocs/patinha/main/patinha.c
 * (led_init/led_set_rgb/led_tick), generalized from patinha's 3 fixed
 * patterns (white solid, blue single-blink, green slow-blink) into a
 * pattern+duration API so board/node can drive all six blueprint states.
 */
#pragma once

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    SIOT_LED_OFF = 0,
    SIOT_LED_WHITE_BLINK,     /* setup mode */
    SIOT_LED_WHITE_SOLID,     /* finding the network */
    SIOT_LED_GREEN_BLINK,     /* root node: 250 ms flash every 5 s */
    SIOT_LED_GREEN_SOLID,     /* (unused now) installed cue */
    SIOT_LED_MAGENTA_SOLID,   /* board / router */
    SIOT_LED_RED_SOLID,       /* alarm / fault */
    SIOT_LED_BLUE_BLINK,      /* IDENTIFY (1 s period) */
    SIOT_LED_BLUE_SOLID,      /* used as a one-shot pulse: message traffic */
} siot_led_pattern_t;

/* Configures the RGB GPIOs (LEDC/PWM) and starts the 50 ms render tick.
 * Call once at boot. */
void siot_led_init(void);

/* Sets the current pattern.
 *
 * duration_ms == 0: pattern is shown until the next siot_led_set_pattern()
 * call (e.g. SIOT_LED_WHITE_BLINK while in setup mode, SIOT_LED_RED_SOLID
 * while a fault is active).
 *
 * duration_ms  > 0: pattern is shown for that long, then the engine reverts
 * to the last steady pattern (the last duration_ms == 0 call, SIOT_LED_OFF
 * at boot). Use this for the transient patterns:
 *   - SIOT_LED_GREEN_SOLID, 3000   -> "green solid 3 s = installed"
 *   - SIOT_LED_BLUE_BLINK, <n*1000> -> COMMAND IDENTIFY for n seconds
 *   - SIOT_LED_BLUE_BLINK, ~500     -> short test-button blip
 */
void siot_led_set_pattern(siot_led_pattern_t pattern, uint32_t duration_ms);

/* The steady pattern a transient one reverts to (last duration_ms == 0). */
siot_led_pattern_t siot_led_get_base(void);

/* Bench visibility (no serial on the board, POC-BRIEF §4.2): every frame
 * sent or received calls siot_led_comm_blink(): ONE blue pulse of
 * SIOT_LED_COMM_BLINK_MS (role colour off meanwhile), then the role colour
 * returns. Frames arriving while a pulse is still lit do not restart it, so
 * a burst never turns into a solid blue. */
#define SIOT_LED_COMM_BLINK_MS 150
void siot_led_comm_blink(void);

#ifdef __cplusplus
}
#endif
