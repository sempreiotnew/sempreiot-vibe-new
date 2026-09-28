/* siot_board_def — which GPIO does what on this unit (brief §1 table, §2).
 *
 * The table itself is generated from tools/pinmap/pinmap.yaml; C code never
 * carries a pin number. app_main selects the entry for CONFIG_SIOT_DEV_MODEL
 * (brief §3 step 3), every hal/ui component then reads siot_board_def().
 */
#pragma once

#include <stdbool.h>
#include <stdint.h>

#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

#define SIOT_PIN_NONE (-1)

typedef struct {
    const char *model;      /* the unit's product model (factory identity; reference §2.1) */
    const char *family;     /* the firmware image it runs: "board" | "node" | "leaf" */
    uint8_t     hw_rev;     /* 0 = any revision (nothing on the sticker yet, brief §14 item 14) */
    bool        is_default; /* the entry used when no model matches */
    int         led_r, led_g, led_b;   /* RGB LED (LEDC) */
    int         button;                /* RST/TEST, pull-up, active low */
    int         acok;                  /* pull-up, 0 = AC present */
    int         uart0_tx, uart0_rx;    /* flash / console / bench tablet link */
    int         usb_dm, usb_dp;        /* native USB-Serial-JTAG */
    bool        led_active_low;
} siot_board_def_t;

/* Picks the entry for `model` (exact string) and `hw_rev` (an entry with
 * hw_rev 0 matches any). Unknown model → the default entry is selected and
 * ESP_ERR_NOT_FOUND is returned so the caller can log it; the unit still
 * has a LED and a button. */
esp_err_t siot_board_def_select(const char *model, uint8_t hw_rev);

/* The selected entry (the default one until siot_board_def_select ran). */
const siot_board_def_t *siot_board_def(void);

#ifdef __cplusplus
}
#endif
