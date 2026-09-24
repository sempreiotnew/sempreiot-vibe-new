/*
 * Board factory-reset button (GPIO21, same pin as pocs/patinha's RST/TESTE
 * and pocs/node's node_button.c) -- blueprint §2-§3 / POC-BRIEF.md §4.1:
 * "the button is held >= 5 s at any time" -> erase siot_inst, reboot into
 * setup mode. The board has no MANUAL_TEST/alarm concept of its own (that's
 * AC-node behaviour, POC-BRIEF §4.3), so unlike node_button.c this only ever
 * does the long-press factory reset -- no short/double press callbacks.
 *
 * Debounce/edge-detection pattern ported from pocs/patinha/main/patinha.c,
 * same structure as pocs/node/main/node_button.c minus the double-press
 * logic.
 */
#pragma once

#ifdef __cplusplus
extern "C" {
#endif

/* Starts GPIO + debounce task. Safe to call in setup mode (before an
 * installation exists) or normal mode -- the >=5s hold is handled
 * internally in both cases. */
void board_button_start(void);

#ifdef __cplusplus
}
#endif
