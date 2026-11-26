/* siot_sensing_rules — see siot_sensing_rules.h. Pure C: nothing here may
 * include an IDF header (it is compiled for the linux host tests and its
 * state lives in RTC memory on a battery unit). */
#include "siot_sensing_rules.h"

#include <stddef.h>
#include <string.h>

/* The newest samples that make the "current" value are the ones younger than this. */
#define CURRENT_SPAN_S   SIOT_SENSE_RISE_AVG_SAMPLES
/* The reference is the samples taken 60..63 s ago. */
#define REFERENCE_SPAN_S (SIOT_SENSE_RISE_AVG_SAMPLES - 1)

/* ---- history ---------------------------------------------------------------- */

/* Index in the ring of the i-th newest sample (0 = the newest). */
static size_t hist_index(const siot_sensing_rules_t *r, size_t i)
{
    return ((size_t)r->hist_head + SIOT_SENSE_HISTORY - 1u - i) % SIOT_SENSE_HISTORY;
}

static void hist_push(siot_sensing_rules_t *r, uint32_t now_s, int32_t temp_c100)
{
    if (temp_c100 > INT16_MAX) temp_c100 = INT16_MAX;
    if (temp_c100 < INT16_MIN) temp_c100 = INT16_MIN;
    r->hist_s[r->hist_head] = now_s;
    r->hist_c100[r->hist_head] = (int16_t)temp_c100;
    r->hist_head = (uint8_t)((r->hist_head + 1u) % SIOT_SENSE_HISTORY);
    if (r->hist_count < SIOT_SENSE_HISTORY) r->hist_count++;
}

/* ---- rate of rise ------------------------------------------------------------- */

/* Current value (mean of the newest samples) at least 8.0 C above the
 * reference taken 60 s earlier? The newest sample is the one just stored. */
static bool rise_reached(const siot_sensing_rules_t *r, uint32_t now_s)
{
    /* Current: up to 4 of the newest samples, none older than 3 s. */
    int32_t cur_sum = 0, cur_n = 0;
    size_t i = 0;
    for (; i < r->hist_count && cur_n < SIOT_SENSE_RISE_AVG_SAMPLES; i++) {
        const size_t k = hist_index(r, i);
        if (now_s - r->hist_s[k] >= CURRENT_SPAN_S) break;
        cur_sum += r->hist_c100[k];
        cur_n++;
    }
    if (cur_n == 0) return false;

    /* Reference: the samples taken 60..63 s ago; with none there (a battery
     * unit between two wakes), the oldest one inside the window that is not
     * part of the current value. Going from newer to older, the last match of
     * the second kind is the oldest. */
    int32_t ref_sum = 0, ref_n = 0;
    bool    have_oldest = false;
    int32_t oldest = 0;
    for (; i < r->hist_count; i++) {
        const size_t   k = hist_index(r, i);
        const uint32_t age = now_s - r->hist_s[k];
        if (age > SIOT_SENSE_RISE_WINDOW_S + REFERENCE_SPAN_S) break;
        if (age >= SIOT_SENSE_RISE_WINDOW_S) {
            ref_sum += r->hist_c100[k];
            ref_n++;
        } else {
            oldest = r->hist_c100[k];
            have_oldest = true;
        }
    }
    if (ref_n == 0) {
        if (!have_oldest) return false;
        ref_sum = oldest;
        ref_n = 1;
    }
    /* cur_sum / cur_n - ref_sum / ref_n >= 8.0 C, without the divisions. */
    return cur_sum * ref_n - ref_sum * cur_n >= SIOT_SENSE_RISE_C100 * cur_n * ref_n;
}

/* ---- the rules ---------------------------------------------------------------- */

void siot_sensing_rules_init(siot_sensing_rules_t *r, bool battery_unit, uint32_t now_s)
{
    memset(r, 0, sizeof(*r));
    r->battery = battery_unit ? 1 : 0;
    r->init_s = now_s;
}

static bool confirm_over(const siot_sensing_rules_t *r, uint32_t now_s)
{
    return now_s - r->confirm_start_s >= SIOT_SENSE_CONFIRM_MAX_S;
}

static void confirm_close(siot_sensing_rules_t *r, bool false_wake)
{
    r->confirming = 0;
    if (false_wake && r->false_wakes < UINT16_MAX) r->false_wakes++;
}

static uint32_t heat_step(siot_sensing_rules_t *r, uint32_t now_s, int32_t temp_c100)
{
    if (r->heat_alarm) {
        /* Waiting for the temperature to come back: 60 samples in a row below 54. */
        if (temp_c100 >= SIOT_SENSE_HEAT_RESTORE_C100) {
            r->heat_n = 0;
            return 0;
        }
        if (++r->heat_n < SIOT_SENSE_HEAT_RESTORE_SAMPLES) return 0;
        r->heat_alarm = 0;
        r->heat_n = 0;
        return SIOT_SENSE_ACT_HEAT_RESTORE;
    }

    /* Fixed temperature first: when both rules are met on one sample the
     * alarm is the fixed one. */
    if (temp_c100 >= SIOT_SENSE_HEAT_FIXED_C100) {
        if (++r->heat_n >= SIOT_SENSE_HEAT_FIXED_SAMPLES) {
            r->heat_alarm = 1;
            r->heat_n = 0;
            return SIOT_SENSE_ACT_HEAT_ALARM;
        }
    } else {
        r->heat_n = 0;
    }

    if (now_s - r->init_s >= SIOT_SENSE_RISE_GUARD_S && rise_reached(r, now_s)) {
        r->heat_alarm = 1;
        r->heat_n = 0;
        return SIOT_SENSE_ACT_RISE_ALARM;
    }
    return 0;
}

static uint32_t wet_step(siot_sensing_rules_t *r, int32_t rh_c100)
{
    const uint8_t need = r->battery ? SIOT_SENSE_WET_WAKES_BATTERY : SIOT_SENSE_WET_SAMPLES_MAINS;
    const bool    counts = r->wet ? rh_c100 < SIOT_SENSE_WET_RELEASE_C100 : rh_c100 >= SIOT_SENSE_WET_C100;

    if (!counts) {
        r->wet_n = 0;
        return 0;
    }
    if (++r->wet_n < need) return 0;
    r->wet_n = 0;
    r->wet = r->wet ? 0 : 1;
    return r->wet ? SIOT_SENSE_ACT_WET_SET : SIOT_SENSE_ACT_WET_CLEAR;
}

/* A read that failed (good=false) or worked: 3 in a row either way. */
static uint32_t fault_step(siot_sensing_rules_t *r, bool good)
{
    if (good == (r->fault != 0)) {
        /* What moves the state: a good read in a fault, a failed one outside. */
        if (++r->fault_n < SIOT_SENSE_FAULT_SAMPLES) return 0;
        r->fault_n = 0;
        r->fault = r->fault ? 0 : 1;
        return r->fault ? SIOT_SENSE_ACT_FAULT_SET : SIOT_SENSE_ACT_FAULT_CLEAR;
    }
    r->fault_n = 0;
    return 0;
}

uint32_t siot_sensing_rules_sample(siot_sensing_rules_t *r, uint32_t now_s, siot_sense_kind_t kind,
                                   bool ok, int32_t temp_c100, int32_t rh_c100)
{
    /* On a battery unit humidity is judged at the 60 s wake only. */
    const bool wet_counts = !r->battery || kind == SIOT_SENSE_WAKE;
    uint32_t   act = fault_step(r, ok);

    if (ok) {
        hist_push(r, now_s, temp_c100);
        if (r->battery && kind == SIOT_SENSE_WAKE) {
            r->last_wake_c100 = r->hist_c100[hist_index(r, 0)];
            r->has_wake = 1;
        }
        act |= heat_step(r, now_s, temp_c100);
        if (wet_counts) act |= wet_step(r, rh_c100);
    } else {
        r->heat_n = 0;
        if (wet_counts) r->wet_n = 0;
    }

    /* The confirmation window of a sensor wake: an alarm ends it; otherwise it
     * ends at its time, once no fixed-temperature count is still running (that
     * count keeps the unit awake by itself and may yet become the alarm). */
    if (r->confirming) {
        if (r->heat_alarm) {
            confirm_close(r, false);
        } else if (confirm_over(r, now_s) && r->heat_n == 0) {
            confirm_close(r, true);
        }
    }
    return act;
}

void siot_sensing_rules_sensor_wake(siot_sensing_rules_t *r, uint32_t now_s)
{
    if (r->confirming) {
        if (!confirm_over(r, now_s)) return;   /* still inside the window: it is the same wake */
        confirm_close(r, !r->heat_alarm);      /* the unit slept before a sample closed it      */
    }
    r->confirming = 1;
    r->confirm_start_s = now_s;
}

bool siot_sensing_rules_stay_awake(const siot_sensing_rules_t *r, uint32_t now_s)
{
    if (r->heat_alarm || r->heat_n > 0) return true;
    return r->confirming && !confirm_over(r, now_s);
}

int32_t siot_sensing_rules_arm_c100(const siot_sensing_rules_t *r)
{
    if (!r->has_wake) return SIOT_SENSE_HEAT_FIXED_C100;
    const int32_t arm = (int32_t)r->last_wake_c100 + SIOT_SENSE_WAKE_MARGIN_C100;
    return arm < SIOT_SENSE_HEAT_FIXED_C100 ? arm : SIOT_SENSE_HEAT_FIXED_C100;
}

bool siot_sensing_rules_heat_alarm(const siot_sensing_rules_t *r) { return r->heat_alarm != 0; }
bool siot_sensing_rules_wet(const siot_sensing_rules_t *r) { return r->wet != 0; }
bool siot_sensing_rules_fault(const siot_sensing_rules_t *r) { return r->fault != 0; }
uint16_t siot_sensing_rules_false_wakes(const siot_sensing_rules_t *r) { return r->false_wakes; }

/* ---- HDC2080 numbers ------------------------------------------------------------ */

/* T = n / steps * 165 - 40.5, in centi-degrees: n * 16500 / steps - 4050. */
#define HDC_SPAN_C100   16500
#define HDC_OFFSET_C100 4050

uint8_t siot_sensing_th_code_floor(int32_t temp_c100)
{
    if (temp_c100 <= -HDC_OFFSET_C100) return 0;
    if (temp_c100 >= siot_sensing_th_code_c100(255)) return 255;
    return (uint8_t)(((temp_c100 + HDC_OFFSET_C100) * 256) / HDC_SPAN_C100);
}

int32_t siot_sensing_th_code_c100(uint8_t code)
{
    /* Rounded up: never below the real step, so the floor of it is the code again. */
    return ((int32_t)code * HDC_SPAN_C100 + 255) / 256 - HDC_OFFSET_C100;
}

int32_t siot_sensing_raw_to_temp_c100(uint16_t raw, uint16_t supply_mv)
{
    int32_t t = (int32_t)(((uint32_t)raw * HDC_SPAN_C100 + 32768u) / 65536u) - HDC_OFFSET_C100;
    if (supply_mv > 1800) {
        /* 0.08 C per volt = 8 centi-C per 1000 mV, to the nearest centi-degree. */
        t -= (((int32_t)supply_mv - 1800) * 8 + 500) / 1000;
    }
    return t;
}

int32_t siot_sensing_raw_to_rh_c100(uint16_t raw)
{
    return (int32_t)(((uint32_t)raw * 10000u + 32768u) / 65536u);
}
