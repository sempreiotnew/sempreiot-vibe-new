/*
 * Node test button (GPIO21, same pin as pocs/patinha's RST/TESTE) --
 * POC-BRIEF.md §4.3: short press -> MANUAL_TEST, double press -> alarm,
 * hold >= 5 s -> factory reset (erase siot_inst, reboot into setup mode),
 * blueprint: "the button is held >= 5 s at any time".
 *
 * Debounce/edge-detection pattern ported from pocs/patinha/main/patinha.c
 * (GPIO ANYEDGE interrupt -> notified task, N stable samples to accept a
 * level change); double-press detection is new (patinha only has one button
 * action per press).
 */
#pragma once

#ifdef __cplusplus
extern "C" {
#endif

typedef void (*node_button_event_cb_t)(void);

/* Starts GPIO + debounce task. Safe to call in setup mode (before an
 * installation exists) or normal mode -- the >=5s factory-reset hold is
 * handled internally in both cases; `on_short_press`/`on_double_press` may
 * be NULL (e.g. not registered yet while still in setup mode). */
void node_button_start(node_button_event_cb_t on_short_press,
                       node_button_event_cb_t on_double_press);

#ifdef __cplusplus
}
#endif
