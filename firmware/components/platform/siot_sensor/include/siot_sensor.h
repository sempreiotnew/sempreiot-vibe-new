/* siot_sensor — one reading interface for the detector's sensors and battery.
 * The units fill HEARTBEAT / EVENT fields (spec §7.1, §7.3) from it and never
 * touch a sensor driver directly.
 *
 * Backends: MOCK (CONFIG_SIOT_SENSOR_MOCK, devkits) and the HDC2080
 * temperature / humidity sensor (src/hdc2080.c). The rules that judge the
 * readings are NOT here: features/siot_sensing (protocol §7.1.6).
 *
 * HDC2080 — the one rule about its interrupt pin (datasheet §8.3.4, brief
 * §2.4.1): the pin shows ONE interrupt source at a time, by fixed priority
 * TH > TL > HH > HL; it is not an OR. This driver enables TEMPERATURE-HIGH
 * ONLY, so the pin means exactly "the temperature is above the armed
 * threshold". Never enable another source "as a convenience": humidity is
 * read and judged by the firmware. The configuration read-back fails a
 * reading if register 0x07 is anything but TH only. */
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
/* Name of the backend for the boot log ("mock", "hdc2080", "none"). */
const char *siot_sensor_backend(void);

/* ---- temperature / humidity at full resolution (features/siot_sensing) ---- */

typedef struct {
    bool    ok;         /* false: the exchange failed, the sensor is not the HDC2080, or it lost its configuration */
    int32_t temp_c100;  /* centi-degrees C (5700 = 57.00 °C), supply correction applied */
    int32_t rh_c100;    /* centi-percent (9970 = 99.70 %) */
} siot_sensor_env_t;

/* This unit has a temperature / humidity sensor (the mock counts). False on a
 * model whose pin map has no sensor bus: nothing is then reported or judged. */
bool siot_sensor_env_present(void);
/* One reading; the sensor converts by itself once per second (auto mode), this
 * only fetches the last conversion. Returns out->ok. */
bool siot_sensor_env_read(siot_sensor_env_t *out);
/* Arm the sensor's temperature-high interrupt at an 8-bit threshold code
 * (HDC2080 register 0x0B: T = code / 256 × 165 − 40.5 °C; 151 = 56.83 °C). */
esp_err_t siot_sensor_heat_arm(uint8_t th_code);
/* Read-and-clear the interrupt status (HDC2080 register 0x04; bit 6 = TH).
 * Reading it releases the interrupt pin. 0 on the mock or on a failed read. */
uint8_t siot_sensor_int_status(void);
#define SIOT_SENSOR_INT_TH 0x40
/* The GPIO the sensor's interrupt arrives on (active low), or -1. */
int siot_sensor_int_pin(void);

#ifdef __cplusplus
}
#endif
