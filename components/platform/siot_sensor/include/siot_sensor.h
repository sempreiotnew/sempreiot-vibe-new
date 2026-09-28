/* siot_sensor — one reading interface for the detector's sensors and battery.
 * The leaf fills HEARTBEAT / EVENT fields (spec §7.1, §7.3) from it and never
 * touches a sensor driver directly. Mock backend only until the PCB exists. */
#pragma once

#include <stdbool.h>
#include <stdint.h>

#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    uint16_t smoke_raw;   /* SMOKE field; 0xFFFF = not available */
    int16_t  temp_x10;    /* TEMP field, tenths of °C; 0x7FFF = n/a */
    uint8_t  humidity;    /* %; 0xFF = n/a */
    bool     valid;
} siot_sensor_reading_t;

esp_err_t siot_sensor_init(void);
void      siot_sensor_read(siot_sensor_reading_t *out);
/* BATTERY_PCT for HEARTBEAT / EVENT (0..100; 0xFF = n/a). */
uint8_t   siot_sensor_battery_pct(void);
/* Name of the backend for the boot log ("mock", later "adpd188bi"). */
const char *siot_sensor_backend(void);

#ifdef __cplusplus
}
#endif
