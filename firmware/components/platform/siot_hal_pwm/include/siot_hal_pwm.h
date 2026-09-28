/* siot_hal_pwm — LEDC channels for the RGB LED (brief §1: LEDC low-speed,
 * timer 0, 8-bit, 5 kHz). From the led_hw_init/led_set_rgb pair in
 * pocs/components/siot_led/siot_led.c (itself from pocs/patinha). */
#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

#define SIOT_HAL_PWM_CHANNELS_MAX 3
#define SIOT_HAL_PWM_DUTY_MAX     255   /* 8-bit resolution */

/* One LEDC timer (5 kHz, 8-bit) and one channel per pin, all starting at 0.
 * `active_low` inverts every duty written later (common-anode LED). */
esp_err_t siot_hal_pwm_init(const int *pins, size_t count, bool active_low);

/* duty 0..255 on channel `idx` (the order of `pins` in init). */
esp_err_t siot_hal_pwm_set(size_t idx, uint8_t duty);

#ifdef __cplusplus
}
#endif
