/* siot_ui_button — the RST/TEST button (brief §1 pin table, §3 step 5).
 *
 *   short tap                       → SIOT_EVT_BUTTON_TAP        (MANUAL_TEST)
 *   2nd press within 500 ms         → SIOT_EVT_BUTTON_DOUBLE_TAP (bench ALARM)
 *   held ≥ 5 s                      → SIOT_EVT_BUTTON_HOLD, then factory reset:
 *                                     SIOT_EVT_FACTORY_RESET, siot_config erased,
 *                                     reboot into setup mode (blueprint "any time")
 *
 * Debounce 10 ms × 3 samples, any-edge interrupt waking a task. Ported from
 * pocs/node/main/node_button.c (superset of pocs/board/main/board_button.c);
 * the callbacks became bus events.
 */
#pragma once

#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Pin from siot_board_def. Safe in every mode; the hold is armed even
 * before an installation exists. */
esp_err_t siot_ui_button_init(void);

#ifdef __cplusplus
}
#endif
