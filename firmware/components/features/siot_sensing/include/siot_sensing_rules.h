/* siot_sensing_rules — the heat and humidity rules of a unit, as pure logic
 * (protocol §7.1.6; every number: phase 5 brief §4).
 *
 * No hardware, no RTOS, no IDF header: the caller reads the sensor and feeds
 * one sample at a time with its own monotonic clock; the answer is a bitmask
 * of what just changed. The state is plain data with no pointers, so a battery
 * unit keeps it in RTC memory across deep sleep.
 *
 * Units: temperature in centi-degrees C (5700 = 57.00 C), humidity in
 * centi-percent (9970 = 99.70 %), time in monotonic seconds. */
#pragma once

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define SIOT_SENSE_HEAT_FIXED_C100      5700   /* alarm: reading >= 57.0 C            */
#define SIOT_SENSE_HEAT_FIXED_SAMPLES   3      /* consecutive 1 s samples             */
#define SIOT_SENSE_HEAT_RESTORE_C100    5400   /* back to normal: < 54.0 C ...        */
#define SIOT_SENSE_HEAT_RESTORE_SAMPLES 60     /* ... for 60 consecutive samples      */
#define SIOT_SENSE_RISE_C100            800    /* alarm: >= 8.0 C ...                 */
#define SIOT_SENSE_RISE_WINDOW_S        60     /* ... within 60 s                     */
#define SIOT_SENSE_RISE_AVG_SAMPLES     4
#define SIOT_SENSE_RISE_GUARD_S         120    /* no rate of rise after power-up      */
#define SIOT_SENSE_WAKE_MARGIN_C100     400    /* battery unit: chip threshold = last wake reading + 4.0 C */
#define SIOT_SENSE_CONFIRM_MAX_S        60     /* battery unit: awake at most this long after a sensor wake */
#define SIOT_SENSE_WET_C100             9970
#define SIOT_SENSE_WET_RELEASE_C100     9500
#define SIOT_SENSE_WET_SAMPLES_MAINS    10
#define SIOT_SENSE_WET_WAKES_BATTERY    2
#define SIOT_SENSE_FAULT_SAMPLES        3
#define SIOT_SENSE_HISTORY              64

/* TICK = one of the 1 s samples of an awake unit; WAKE = a battery unit's
 * reading at its 60 s timer wake. A mains unit only ever feeds TICK. */
typedef enum { SIOT_SENSE_TICK = 0, SIOT_SENSE_WAKE = 1 } siot_sense_kind_t;

/* Bitmask returned by siot_sensing_rules_sample(): what just changed. */
#define SIOT_SENSE_ACT_HEAT_ALARM   0x01  /* fixed temperature alarm fired        */
#define SIOT_SENSE_ACT_RISE_ALARM   0x02  /* rate-of-rise alarm fired             */
#define SIOT_SENSE_ACT_HEAT_RESTORE 0x04  /* temperature back to normal after an alarm */
#define SIOT_SENSE_ACT_WET_SET      0x08
#define SIOT_SENSE_ACT_WET_CLEAR    0x10
#define SIOT_SENSE_ACT_FAULT_SET    0x20
#define SIOT_SENSE_ACT_FAULT_CLEAR  0x40

/* The whole state: plain data, no pointers, about 400 bytes. Treat the fields as
 * private; they are here so the struct can be placed (RTC memory, static). */
typedef struct {
    uint32_t init_s;                          /* when the rules started: the rate-of-rise guard */
    uint32_t confirm_start_s;                 /* battery: when the open confirmation window began */
    uint32_t hist_s[SIOT_SENSE_HISTORY];      /* ring of the last good samples: when ...          */
    int16_t  hist_c100[SIOT_SENSE_HISTORY];   /* ... and what                                     */
    int16_t  last_wake_c100;                  /* battery: the last WAKE reading (if has_wake)     */
    uint16_t false_wakes;
    uint8_t  hist_head;                       /* where the next sample goes                       */
    uint8_t  hist_count;
    uint8_t  heat_n;                          /* not in alarm: samples >= 57 in a row; in alarm: samples < 54 in a row */
    uint8_t  wet_n;                           /* not wet: readings >= 99.7 in a row; wet: readings < 95 in a row       */
    uint8_t  fault_n;                         /* no fault: failed reads in a row; fault: good reads in a row           */
    uint8_t  battery;
    uint8_t  heat_alarm;
    uint8_t  wet;
    uint8_t  fault;
    uint8_t  has_wake;
    uint8_t  confirming;                      /* battery: a confirmation window is open           */
} siot_sensing_rules_t;

/* Start from nothing at now_s (power-up): empty history, no alarm, the 120 s
 * rate-of-rise guard running. A battery unit calls it once per power-up, not
 * once per wake. */
void siot_sensing_rules_init(siot_sensing_rules_t *r, bool battery_unit, uint32_t now_s);

/* Feed one reading. ok=false: the read failed (I2C error, wrong identity, lost
 * configuration) — temp/rh are ignored, nothing is stored and every count of
 * consecutive good samples starts over. Returns SIOT_SENSE_ACT_* bits. */
uint32_t siot_sensing_rules_sample(siot_sensing_rules_t *r, uint32_t now_s, siot_sense_kind_t kind,
                                   bool ok, int32_t temp_c100, int32_t rh_c100);

/* Battery unit: a sensor (interrupt) wake happened at now_s: start the
 * confirmation window. Ignored while a window is still running. */
void siot_sensing_rules_sensor_wake(siot_sensing_rules_t *r, uint32_t now_s);

/* Battery unit: must the unit stay awake sampling at 1 Hz? (confirmation
 * running, a fixed-temperature count in progress, or a heat alarm not yet
 * restored) */
bool siot_sensing_rules_stay_awake(const siot_sensing_rules_t *r, uint32_t now_s);

/* Battery unit: the temperature to arm in the chip before sleeping
 * (min(57.0, last WAKE reading + 4.0); 57.0 before any WAKE reading), centi-C.
 * Convert with siot_sensing_th_code_floor(). */
int32_t siot_sensing_rules_arm_c100(const siot_sensing_rules_t *r);

bool siot_sensing_rules_heat_alarm(const siot_sensing_rules_t *r);   /* in a heat alarm, not restored */
bool siot_sensing_rules_wet(const siot_sensing_rules_t *r);
bool siot_sensing_rules_fault(const siot_sensing_rules_t *r);

/* Sensor wakes that ended without an alarm (saturates at 65535). A window is
 * closed, and counted, by the first sample() or sensor_wake() at or after its
 * end — not by the clock alone. */
uint16_t siot_sensing_rules_false_wakes(const siot_sensing_rules_t *r);

/* HDC2080 8-bit threshold register <-> temperature (datasheet eq. 7/9:
 * T = code/256*165 - 40.5). */
uint8_t siot_sensing_th_code_floor(int32_t temp_c100);  /* highest code whose temperature is <= temp; clamped 0..255 */
int32_t siot_sensing_th_code_c100(uint8_t code);        /* rounded up to the centi-degree, so floor(c100(code)) == code */

/* HDC2080 raw 16-bit results -> centi units (datasheet eq. 1 and 3:
 * T = raw/65536*165 - 40.5; RH = raw/65536*100), rounded to the nearest.
 * supply_mv applies eq. 2: subtract 0.08 C per volt above 1.8 V. */
int32_t siot_sensing_raw_to_temp_c100(uint16_t raw, uint16_t supply_mv);
int32_t siot_sensing_raw_to_rh_c100(uint16_t raw);

#ifdef __cplusplus
}
#endif
