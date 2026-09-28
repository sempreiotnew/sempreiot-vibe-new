/* siot_hal_gpio — digital inputs (button, ACOK) without exposing driver/gpio.h
 * to the layers above (brief §2). Pins come from siot_board_def.
 *
 * GPIO configuration pattern from pocs/patinha/main/patinha.c and
 * pocs/node/main/node_button.c (pull-up input, any-edge interrupt that wakes
 * a debounce task).
 */
#pragma once

#include <stdbool.h>

#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Configures `pin` as an input with the internal pull-up on/off. */
esp_err_t siot_hal_gpio_input_init(int pin, bool pull_up);

/* Raw level, 0 or 1 (-1 for SIOT_PIN_NONE). */
int siot_hal_gpio_read(int pin);

/* Runs in ISR context on every edge of `pin`: do nothing but wake a task. */
typedef void (*siot_hal_gpio_edge_cb_t)(int pin, void *ctx);

/* Enables an any-edge interrupt on an input pin. Installs the GPIO ISR
 * service on first use. */
esp_err_t siot_hal_gpio_edge_subscribe(int pin, siot_hal_gpio_edge_cb_t cb, void *ctx);

#ifdef __cplusplus
}
#endif
