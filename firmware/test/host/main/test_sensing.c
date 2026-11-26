/* Protocol §7.1.6 (v3.16), phase 5 brief §4: the heat and humidity rules of a
 * unit, and the HDC2080 number conversions — siot_sensing_rules, no hardware. */
#include "unity.h"

#include "siot_sensing_rules.h"

#define DRY 4000 /* 40 % */

/* One 1 s sample of an awake unit: the clock moves, then the reading. */
static uint32_t tick(siot_sensing_rules_t *r, uint32_t *t, int32_t temp)
{
    *t += 1;
    return siot_sensing_rules_sample(r, *t, SIOT_SENSE_TICK, true, temp, DRY);
}

/* n such samples at one temperature; every action seen, OR-ed. */
static uint32_t hold(siot_sensing_rules_t *r, uint32_t *t, int n, int32_t temp)
{
    uint32_t act = 0;
    for (int i = 0; i < n; i++) act |= tick(r, t, temp);
    return act;
}

/* A battery unit's 60 s timer wake. */
static uint32_t wake(siot_sensing_rules_t *r, uint32_t t, int32_t temp, int32_t rh)
{
    return siot_sensing_rules_sample(r, t, SIOT_SENSE_WAKE, true, temp, rh);
}

/* ---- fixed temperature ---------------------------------------------------------- */

TEST_CASE("sensing fixed: 57.0 C fires on the 3rd sample in a row, not the 2nd", "[sensing]")
{
    siot_sensing_rules_t r;
    uint32_t t = 0;
    siot_sensing_rules_init(&r, false, t);
    TEST_ASSERT_EQUAL_HEX32(0, hold(&r, &t, 5, 2500));
    TEST_ASSERT_EQUAL_HEX32(0, hold(&r, &t, 5, 5699)); /* 56.99 is not 57 */
    TEST_ASSERT_EQUAL_HEX32(0, tick(&r, &t, 5700));
    TEST_ASSERT_EQUAL_HEX32(0, tick(&r, &t, 5700));
    TEST_ASSERT_FALSE(siot_sensing_rules_heat_alarm(&r));
    TEST_ASSERT_EQUAL_HEX32(SIOT_SENSE_ACT_HEAT_ALARM, tick(&r, &t, 5700));
    TEST_ASSERT_TRUE(siot_sensing_rules_heat_alarm(&r));
}

TEST_CASE("sensing fixed: a spike, or two, is not an alarm", "[sensing]")
{
    siot_sensing_rules_t r;
    uint32_t t = 0;
    siot_sensing_rules_init(&r, false, t);
    static const int32_t seq[] = { 2500, 6000, 2500, 6000, 6000, 2500, 6000, 6000, 5699, 6000 };
    for (size_t i = 0; i < sizeof(seq) / sizeof(seq[0]); i++) TEST_ASSERT_EQUAL_HEX32(0, tick(&r, &t, seq[i]));
    TEST_ASSERT_FALSE(siot_sensing_rules_heat_alarm(&r));
}

TEST_CASE("sensing fixed: back to normal after 60 samples below 54, then armed again", "[sensing]")
{
    siot_sensing_rules_t r;
    uint32_t t = 0;
    siot_sensing_rules_init(&r, false, t);
    TEST_ASSERT_EQUAL_HEX32(SIOT_SENSE_ACT_HEAT_ALARM, hold(&r, &t, 3, 5800));
    /* 54.0 itself is not below 54: it starts the count over. */
    TEST_ASSERT_EQUAL_HEX32(0, hold(&r, &t, 59, 5399));
    TEST_ASSERT_EQUAL_HEX32(0, tick(&r, &t, 5400));
    TEST_ASSERT_EQUAL_HEX32(0, hold(&r, &t, 59, 5399));
    TEST_ASSERT_TRUE(siot_sensing_rules_heat_alarm(&r));
    TEST_ASSERT_EQUAL_HEX32(SIOT_SENSE_ACT_HEAT_RESTORE, tick(&r, &t, 5399));
    TEST_ASSERT_FALSE(siot_sensing_rules_heat_alarm(&r));
    /* Armed again: the same three samples fire a second alarm. */
    TEST_ASSERT_EQUAL_HEX32(0, hold(&r, &t, 2, 5700));
    TEST_ASSERT_EQUAL_HEX32(SIOT_SENSE_ACT_HEAT_ALARM, tick(&r, &t, 5700));
}

TEST_CASE("sensing: one alarm per fire — nothing more while it lasts", "[sensing]")
{
    siot_sensing_rules_t r;
    uint32_t t = 0;
    siot_sensing_rules_init(&r, false, t);
    TEST_ASSERT_EQUAL_HEX32(0, hold(&r, &t, 200, 2500)); /* past the power-up guard */
    /* 25 -> 70 C at once: rate of rise is met on the first sample, then the
     * fixed threshold stays met for minutes. One action in all. */
    int alarms = 0;
    for (int i = 0; i < 300; i++) {
        const uint32_t act = tick(&r, &t, 7000);
        if (act & (SIOT_SENSE_ACT_HEAT_ALARM | SIOT_SENSE_ACT_RISE_ALARM)) alarms++;
        TEST_ASSERT_EQUAL_HEX32(0, act & SIOT_SENSE_ACT_HEAT_RESTORE);
    }
    TEST_ASSERT_EQUAL_INT(1, alarms);
    TEST_ASSERT_TRUE(siot_sensing_rules_heat_alarm(&r));
}

/* ---- rate of rise ----------------------------------------------------------------- */

TEST_CASE("sensing rise: 8 C within 60 s fires on a mains unit", "[sensing]")
{
    siot_sensing_rules_t r;
    uint32_t t = 0;
    siot_sensing_rules_init(&r, false, t);
    TEST_ASSERT_EQUAL_HEX32(0, hold(&r, &t, 200, 2500));
    /* 0.15 C per second (9 C a minute). The mean of the 4 newest lags the
     * newest by 1.5 samples: 15 * (k - 1.5) >= 800 first at k = 55. */
    for (int k = 1; k < 55; k++) TEST_ASSERT_EQUAL_HEX32(0, tick(&r, &t, 2500 + 15 * k));
    TEST_ASSERT_EQUAL_HEX32(SIOT_SENSE_ACT_RISE_ALARM, tick(&r, &t, 2500 + 15 * 55));
    TEST_ASSERT_TRUE(siot_sensing_rules_heat_alarm(&r));
}

TEST_CASE("sensing rise: 7.9 C in a minute does not fire", "[sensing]")
{
    siot_sensing_rules_t r;
    uint32_t t = 0;
    siot_sensing_rules_init(&r, false, t);
    TEST_ASSERT_EQUAL_HEX32(0, hold(&r, &t, 200, 2500));
    TEST_ASSERT_EQUAL_HEX32(0, hold(&r, &t, 200, 3290));
}

TEST_CASE("sensing rise: a slow drift never fires (1 C a minute, 40 min, up to 50 C)", "[sensing]")
{
    siot_sensing_rules_t r;
    uint32_t t = 0;
    siot_sensing_rules_init(&r, false, t);
    for (int s = 1; s <= 40 * 60; s++) TEST_ASSERT_EQUAL_HEX32(0, tick(&r, &t, 1000 + (s * 100) / 60));
    TEST_ASSERT_FALSE(siot_sensing_rules_heat_alarm(&r));
}

TEST_CASE("sensing rise: nothing during the 120 s after power-up", "[sensing]")
{
    siot_sensing_rules_t r;
    uint32_t t = 1000;
    siot_sensing_rules_init(&r, false, t);
    TEST_ASSERT_EQUAL_HEX32(0, hold(&r, &t, 10, 2500));
    /* A unit brought in from the cold: +15 C in a second, inside the guard.
     * By the time the guard ends the jump is older than the window. */
    TEST_ASSERT_EQUAL_HEX32(0, hold(&r, &t, 190, 4000));
    /* The same kind of jump after the guard: 4 samples for the mean to get there. */
    TEST_ASSERT_EQUAL_HEX32(0, hold(&r, &t, 3, 5000));
    TEST_ASSERT_EQUAL_HEX32(SIOT_SENSE_ACT_RISE_ALARM, tick(&r, &t, 5000));
}

/* ---- humidity ----------------------------------------------------------------------- */

TEST_CASE("sensing wet: mains unit, 10 samples in a row each way", "[sensing]")
{
    siot_sensing_rules_t r;
    siot_sensing_rules_init(&r, false, 0);
    uint32_t t = 0;
    for (int i = 0; i < 9; i++) TEST_ASSERT_EQUAL_HEX32(0, siot_sensing_rules_sample(&r, ++t, SIOT_SENSE_TICK, true, 2500, 9970));
    /* 99.69 % breaks the run. */
    TEST_ASSERT_EQUAL_HEX32(0, siot_sensing_rules_sample(&r, ++t, SIOT_SENSE_TICK, true, 2500, 9969));
    for (int i = 0; i < 9; i++) TEST_ASSERT_EQUAL_HEX32(0, siot_sensing_rules_sample(&r, ++t, SIOT_SENSE_TICK, true, 2500, 10000));
    TEST_ASSERT_FALSE(siot_sensing_rules_wet(&r));
    TEST_ASSERT_EQUAL_HEX32(SIOT_SENSE_ACT_WET_SET, siot_sensing_rules_sample(&r, ++t, SIOT_SENSE_TICK, true, 2500, 9970));
    TEST_ASSERT_TRUE(siot_sensing_rules_wet(&r));

    /* Between 95 and 99.7 nothing changes; 95.0 itself is not below 95. */
    for (int i = 0; i < 30; i++) TEST_ASSERT_EQUAL_HEX32(0, siot_sensing_rules_sample(&r, ++t, SIOT_SENSE_TICK, true, 2500, 9500));
    for (int i = 0; i < 9; i++) TEST_ASSERT_EQUAL_HEX32(0, siot_sensing_rules_sample(&r, ++t, SIOT_SENSE_TICK, true, 2500, 9499));
    TEST_ASSERT_TRUE(siot_sensing_rules_wet(&r));
    TEST_ASSERT_EQUAL_HEX32(SIOT_SENSE_ACT_WET_CLEAR, siot_sensing_rules_sample(&r, ++t, SIOT_SENSE_TICK, true, 2500, 9499));
    TEST_ASSERT_FALSE(siot_sensing_rules_wet(&r));
}

TEST_CASE("sensing wet: battery unit, 2 wakes in a row each way, ticks do not count", "[sensing]")
{
    siot_sensing_rules_t r;
    siot_sensing_rules_init(&r, true, 0);
    TEST_ASSERT_EQUAL_HEX32(0, wake(&r, 60, 2500, 9990));
    /* Awake for some other reason: twenty wet 1 s samples change nothing ... */
    for (uint32_t t = 61; t <= 80; t++) TEST_ASSERT_EQUAL_HEX32(0, siot_sensing_rules_sample(&r, t, SIOT_SENSE_TICK, true, 2500, 9990));
    /* ... and dry ones do not break the run of wakes either. */
    for (uint32_t t = 81; t <= 90; t++) TEST_ASSERT_EQUAL_HEX32(0, siot_sensing_rules_sample(&r, t, SIOT_SENSE_TICK, true, 2500, DRY));
    TEST_ASSERT_FALSE(siot_sensing_rules_wet(&r));
    TEST_ASSERT_EQUAL_HEX32(SIOT_SENSE_ACT_WET_SET, wake(&r, 120, 2500, 9990));
    TEST_ASSERT_TRUE(siot_sensing_rules_wet(&r));

    TEST_ASSERT_EQUAL_HEX32(0, wake(&r, 180, 2500, 9000));
    TEST_ASSERT_EQUAL_HEX32(0, wake(&r, 240, 2500, 9600)); /* not below 95: starts over */
    TEST_ASSERT_EQUAL_HEX32(0, wake(&r, 300, 2500, 9000));
    TEST_ASSERT_EQUAL_HEX32(SIOT_SENSE_ACT_WET_CLEAR, wake(&r, 360, 2500, 9000));
    TEST_ASSERT_FALSE(siot_sensing_rules_wet(&r));
}

/* ---- sensor fault ----------------------------------------------------------------------- */

TEST_CASE("sensing fault: 3 failed reads set it, 3 good ones clear it", "[sensing]")
{
    siot_sensing_rules_t r;
    uint32_t t = 0;
    siot_sensing_rules_init(&r, false, t);
    TEST_ASSERT_EQUAL_HEX32(0, hold(&r, &t, 5, 2500));
    TEST_ASSERT_EQUAL_HEX32(0, siot_sensing_rules_sample(&r, ++t, SIOT_SENSE_TICK, false, 0, 0));
    TEST_ASSERT_EQUAL_HEX32(0, siot_sensing_rules_sample(&r, ++t, SIOT_SENSE_TICK, false, 0, 0));
    TEST_ASSERT_EQUAL_HEX32(0, tick(&r, &t, 2500)); /* one good read: the run is over */
    TEST_ASSERT_EQUAL_HEX32(0, siot_sensing_rules_sample(&r, ++t, SIOT_SENSE_TICK, false, 0, 0));
    TEST_ASSERT_EQUAL_HEX32(0, siot_sensing_rules_sample(&r, ++t, SIOT_SENSE_TICK, false, 0, 0));
    TEST_ASSERT_FALSE(siot_sensing_rules_fault(&r));
    TEST_ASSERT_EQUAL_HEX32(SIOT_SENSE_ACT_FAULT_SET, siot_sensing_rules_sample(&r, ++t, SIOT_SENSE_TICK, false, 0, 0));
    TEST_ASSERT_TRUE(siot_sensing_rules_fault(&r));
    /* Still failing: said once. */
    for (int i = 0; i < 10; i++) TEST_ASSERT_EQUAL_HEX32(0, siot_sensing_rules_sample(&r, ++t, SIOT_SENSE_TICK, false, 0, 0));

    TEST_ASSERT_EQUAL_HEX32(0, hold(&r, &t, 2, 2500));
    TEST_ASSERT_EQUAL_HEX32(0, siot_sensing_rules_sample(&r, ++t, SIOT_SENSE_TICK, false, 0, 0));
    TEST_ASSERT_EQUAL_HEX32(0, hold(&r, &t, 2, 2500));
    TEST_ASSERT_TRUE(siot_sensing_rules_fault(&r));
    TEST_ASSERT_EQUAL_HEX32(SIOT_SENSE_ACT_FAULT_CLEAR, tick(&r, &t, 2500));
    TEST_ASSERT_FALSE(siot_sensing_rules_fault(&r));
}

TEST_CASE("sensing fault: a failed read breaks the other counts and is not a reading", "[sensing]")
{
    siot_sensing_rules_t r;
    uint32_t t = 0;
    siot_sensing_rules_init(&r, false, t);
    /* Fixed temperature: 2 + failed + 2 is not 3 in a row. The failed read
     * carries a huge "temperature" that must be ignored. */
    TEST_ASSERT_EQUAL_HEX32(0, hold(&r, &t, 2, 5700));
    TEST_ASSERT_EQUAL_HEX32(0, siot_sensing_rules_sample(&r, ++t, SIOT_SENSE_TICK, false, 12000, 10000));
    TEST_ASSERT_EQUAL_HEX32(0, hold(&r, &t, 2, 5700));
    TEST_ASSERT_EQUAL_HEX32(SIOT_SENSE_ACT_HEAT_ALARM, tick(&r, &t, 5700));

    /* Humidity: 9 + failed + 9 is not 10 in a row. */
    siot_sensing_rules_init(&r, false, t);
    for (int i = 0; i < 9; i++) TEST_ASSERT_EQUAL_HEX32(0, siot_sensing_rules_sample(&r, ++t, SIOT_SENSE_TICK, true, 2500, 9990));
    TEST_ASSERT_EQUAL_HEX32(0, siot_sensing_rules_sample(&r, ++t, SIOT_SENSE_TICK, false, 0, 0));
    for (int i = 0; i < 9; i++) TEST_ASSERT_EQUAL_HEX32(0, siot_sensing_rules_sample(&r, ++t, SIOT_SENSE_TICK, true, 2500, 9990));
    TEST_ASSERT_EQUAL_HEX32(SIOT_SENSE_ACT_WET_SET, siot_sensing_rules_sample(&r, ++t, SIOT_SENSE_TICK, true, 2500, 9990));

    /* Rate of rise: failed reads past the guard leave no sample behind — a
     * -40 C or a 0 in the history would look like a rise on the next good one. */
    siot_sensing_rules_init(&r, false, t);
    TEST_ASSERT_EQUAL_HEX32(0, hold(&r, &t, 200, 2500));
    for (int i = 0; i < 2; i++) TEST_ASSERT_EQUAL_HEX32(0, siot_sensing_rules_sample(&r, ++t, SIOT_SENSE_TICK, false, -4050, 0));
    TEST_ASSERT_EQUAL_HEX32(0, hold(&r, &t, 100, 2500));
}

/* ---- battery unit ----------------------------------------------------------------------- */

TEST_CASE("sensing battery: the chip is armed 4 C above the last wake, never above 57", "[sensing]")
{
    siot_sensing_rules_t r;
    siot_sensing_rules_init(&r, true, 0);
    /* Before any reading: the fixed threshold, register code 151 = 56.83 C. */
    TEST_ASSERT_EQUAL_INT32(5700, siot_sensing_rules_arm_c100(&r));
    TEST_ASSERT_EQUAL_UINT8(151, siot_sensing_th_code_floor(siot_sensing_rules_arm_c100(&r)));

    TEST_ASSERT_EQUAL_HEX32(0, wake(&r, 60, 2500, DRY));
    TEST_ASSERT_EQUAL_INT32(2900, siot_sensing_rules_arm_c100(&r));
    const uint8_t code = siot_sensing_th_code_floor(2900);
    TEST_ASSERT_EQUAL_UINT8(107, code); /* 28.47 C: the last step at or below 29.0 */
    TEST_ASSERT_TRUE(siot_sensing_th_code_c100(code) <= 2900);
    TEST_ASSERT_TRUE(siot_sensing_th_code_c100((uint8_t)(code + 1)) > 2900);

    /* A 1 s sample is not the baseline; the next wake is. */
    TEST_ASSERT_EQUAL_HEX32(0, siot_sensing_rules_sample(&r, 61, SIOT_SENSE_TICK, true, 2700, DRY));
    TEST_ASSERT_EQUAL_INT32(2900, siot_sensing_rules_arm_c100(&r));
    TEST_ASSERT_EQUAL_HEX32(0, wake(&r, 120, 2600, DRY));
    TEST_ASSERT_EQUAL_INT32(3000, siot_sensing_rules_arm_c100(&r));
    /* A failed wake keeps the last one. */
    TEST_ASSERT_EQUAL_HEX32(0, siot_sensing_rules_sample(&r, 180, SIOT_SENSE_WAKE, false, 0, 0));
    TEST_ASSERT_EQUAL_INT32(3000, siot_sensing_rules_arm_c100(&r));

    /* A hot room: 55 + 4 is capped at 57. */
    siot_sensing_rules_init(&r, true, 0);
    TEST_ASSERT_EQUAL_HEX32(0, wake(&r, 60, 5500, DRY));
    TEST_ASSERT_EQUAL_INT32(5700, siot_sensing_rules_arm_c100(&r));
    TEST_ASSERT_FALSE(siot_sensing_rules_stay_awake(&r, 60));
}

TEST_CASE("sensing battery: a sensor wake, then +8 C within 60 s of the wake reading, is the alarm", "[sensing]")
{
    siot_sensing_rules_t r;
    siot_sensing_rules_init(&r, true, 0);
    for (uint32_t t = 60; t <= 180; t += 60) TEST_ASSERT_EQUAL_HEX32(0, wake(&r, t, 2500, DRY));
    TEST_ASSERT_FALSE(siot_sensing_rules_stay_awake(&r, 180));

    /* 20 s after the 25 C wake the chip sees 29 C and wakes the unit. */
    siot_sensing_rules_sensor_wake(&r, 200);
    TEST_ASSERT_TRUE(siot_sensing_rules_stay_awake(&r, 200));
    /* 0.2 C per second from 29.0 C. Reference: the 25 C wake at t = 180.
     * Mean of the 4 newest = 29 + 0.2 * (t - 201.5) >= 33 first at t = 222. */
    for (uint32_t t = 200; t < 222; t++) {
        TEST_ASSERT_EQUAL_HEX32(0, siot_sensing_rules_sample(&r, t, SIOT_SENSE_TICK, true, 2900 + 20 * (int32_t)(t - 200), DRY));
        TEST_ASSERT_TRUE(siot_sensing_rules_stay_awake(&r, t));
    }
    TEST_ASSERT_EQUAL_HEX32(SIOT_SENSE_ACT_RISE_ALARM,
                            siot_sensing_rules_sample(&r, 222, SIOT_SENSE_TICK, true, 2900 + 20 * 22, DRY));
    TEST_ASSERT_TRUE(siot_sensing_rules_heat_alarm(&r));
    /* In alarm the unit does not sleep, window or no window, and that wake was a real one. */
    TEST_ASSERT_TRUE(siot_sensing_rules_stay_awake(&r, 222));
    TEST_ASSERT_TRUE(siot_sensing_rules_stay_awake(&r, 1000));
    TEST_ASSERT_EQUAL_UINT16(0, siot_sensing_rules_false_wakes(&r));
}

TEST_CASE("sensing battery: a rise seen only at the 60 s wakes fires too", "[sensing]")
{
    siot_sensing_rules_t r;
    siot_sensing_rules_init(&r, true, 0);
    TEST_ASSERT_EQUAL_HEX32(0, wake(&r, 60, 2500, DRY));
    TEST_ASSERT_EQUAL_HEX32(0, wake(&r, 120, 2500, DRY));
    TEST_ASSERT_EQUAL_HEX32(0, wake(&r, 180, 3299, DRY));  /* +7.99 */
    TEST_ASSERT_EQUAL_HEX32(SIOT_SENSE_ACT_RISE_ALARM, wake(&r, 241, 4100, DRY)); /* a second late: still the reference */
}

TEST_CASE("sensing battery: a sensor wake with no further rise stands down after 60 s", "[sensing]")
{
    siot_sensing_rules_t r;
    siot_sensing_rules_init(&r, true, 0);
    for (uint32_t t = 60; t <= 180; t += 60) TEST_ASSERT_EQUAL_HEX32(0, wake(&r, t, 2500, DRY));

    siot_sensing_rules_sensor_wake(&r, 200);
    /* A second call inside the window is the same wake: it does not extend it. */
    siot_sensing_rules_sensor_wake(&r, 230);
    for (uint32_t t = 200; t < 260; t++) {
        TEST_ASSERT_TRUE(siot_sensing_rules_stay_awake(&r, t));
        TEST_ASSERT_EQUAL_HEX32(0, siot_sensing_rules_sample(&r, t, SIOT_SENSE_TICK, true, 2920, DRY));
    }
    TEST_ASSERT_FALSE(siot_sensing_rules_stay_awake(&r, 260));
    TEST_ASSERT_EQUAL_HEX32(0, siot_sensing_rules_sample(&r, 260, SIOT_SENSE_TICK, true, 2920, DRY));
    TEST_ASSERT_EQUAL_UINT16(1, siot_sensing_rules_false_wakes(&r));
    TEST_ASSERT_FALSE(siot_sensing_rules_stay_awake(&r, 261));
    TEST_ASSERT_FALSE(siot_sensing_rules_heat_alarm(&r));

    /* The unit that went to sleep the moment stay_awake said so: the window
     * is counted by whatever comes next — here the next sensor wake, which
     * opens its own; that one is closed by the following timer wake. */
    siot_sensing_rules_sensor_wake(&r, 400);
    for (uint32_t t = 400; siot_sensing_rules_stay_awake(&r, t); t++)
        TEST_ASSERT_EQUAL_HEX32(0, siot_sensing_rules_sample(&r, t, SIOT_SENSE_TICK, true, 2920, DRY));
    TEST_ASSERT_EQUAL_UINT16(1, siot_sensing_rules_false_wakes(&r));
    siot_sensing_rules_sensor_wake(&r, 500);
    TEST_ASSERT_EQUAL_UINT16(2, siot_sensing_rules_false_wakes(&r));
    TEST_ASSERT_TRUE(siot_sensing_rules_stay_awake(&r, 559));
    TEST_ASSERT_FALSE(siot_sensing_rules_stay_awake(&r, 560));
    TEST_ASSERT_EQUAL_HEX32(0, wake(&r, 600, 2920, DRY));
    TEST_ASSERT_EQUAL_UINT16(3, siot_sensing_rules_false_wakes(&r));
}

TEST_CASE("sensing battery: 57 C at a wake keeps the unit awake until the count is settled", "[sensing]")
{
    siot_sensing_rules_t r;
    siot_sensing_rules_init(&r, true, 0);
    TEST_ASSERT_EQUAL_HEX32(0, wake(&r, 60, 5600, DRY));
    TEST_ASSERT_FALSE(siot_sensing_rules_stay_awake(&r, 60));
    /* The wake reading is the first of the three. */
    TEST_ASSERT_EQUAL_HEX32(0, wake(&r, 120, 5710, DRY));
    TEST_ASSERT_TRUE(siot_sensing_rules_stay_awake(&r, 120));
    TEST_ASSERT_EQUAL_HEX32(0, siot_sensing_rules_sample(&r, 121, SIOT_SENSE_TICK, true, 5690, DRY));
    TEST_ASSERT_FALSE(siot_sensing_rules_stay_awake(&r, 121));

    TEST_ASSERT_EQUAL_HEX32(0, wake(&r, 180, 5710, DRY));
    TEST_ASSERT_EQUAL_HEX32(0, siot_sensing_rules_sample(&r, 181, SIOT_SENSE_TICK, true, 5720, DRY));
    TEST_ASSERT_TRUE(siot_sensing_rules_stay_awake(&r, 181));
    TEST_ASSERT_EQUAL_HEX32(SIOT_SENSE_ACT_HEAT_ALARM, siot_sensing_rules_sample(&r, 182, SIOT_SENSE_TICK, true, 5730, DRY));
    TEST_ASSERT_TRUE(siot_sensing_rules_stay_awake(&r, 182));
    /* 60 samples below 54 and it may sleep again. */
    uint32_t act = 0;
    for (uint32_t t = 183; t < 243; t++) act |= siot_sensing_rules_sample(&r, t, SIOT_SENSE_TICK, true, 5000, DRY);
    TEST_ASSERT_EQUAL_HEX32(SIOT_SENSE_ACT_HEAT_RESTORE, act);
    TEST_ASSERT_FALSE(siot_sensing_rules_stay_awake(&r, 243));
}

/* ---- HDC2080 numbers ---------------------------------------------------------------------- */

TEST_CASE("sensing hdc2080: threshold code <-> temperature", "[sensing]")
{
    TEST_ASSERT_EQUAL_UINT8(151, siot_sensing_th_code_floor(5700));
    TEST_ASSERT_INT32_WITHIN(1, 5683, siot_sensing_th_code_c100(151));
    TEST_ASSERT_INT32_WITHIN(1, 5747, siot_sensing_th_code_c100(152));
    TEST_ASSERT_EQUAL_INT32(-4050, siot_sensing_th_code_c100(0));
    TEST_ASSERT_INT32_WITHIN(1, 12386, siot_sensing_th_code_c100(255));
    /* Clamped at both ends. */
    TEST_ASSERT_EQUAL_UINT8(0, siot_sensing_th_code_floor(-10000));
    TEST_ASSERT_EQUAL_UINT8(0, siot_sensing_th_code_floor(-4050));
    TEST_ASSERT_EQUAL_UINT8(255, siot_sensing_th_code_floor(20000));
    TEST_ASSERT_EQUAL_UINT8(255, siot_sensing_th_code_floor(INT32_MAX));
    TEST_ASSERT_EQUAL_UINT8(0, siot_sensing_th_code_floor(INT32_MIN));
    /* Every code: its own temperature gives it back, one centi-degree less the one below. */
    for (int code = 0; code <= 255; code++) {
        const int32_t c = siot_sensing_th_code_c100((uint8_t)code);
        TEST_ASSERT_EQUAL_UINT8(code, siot_sensing_th_code_floor(c));
        if (code > 0) TEST_ASSERT_EQUAL_UINT8(code - 1, siot_sensing_th_code_floor(c - 1));
    }
}

TEST_CASE("sensing hdc2080: raw results to centi units", "[sensing]")
{
    TEST_ASSERT_EQUAL_INT32(-4050, siot_sensing_raw_to_temp_c100(0, 1800));
    TEST_ASSERT_INT32_WITHIN(1, 2550, siot_sensing_raw_to_temp_c100(0x6666, 1800));
    TEST_ASSERT_INT32_WITHIN(1, 12450, siot_sensing_raw_to_temp_c100(0xFFFF, 1800));
    /* 0.08 C per volt above 1.8 V: 0.12 C at 3.3 V; nothing below 1.8 V. */
    TEST_ASSERT_EQUAL_INT32(siot_sensing_raw_to_temp_c100(0x6666, 1800) - 12, siot_sensing_raw_to_temp_c100(0x6666, 3300));
    TEST_ASSERT_EQUAL_INT32(siot_sensing_raw_to_temp_c100(0x6666, 1800), siot_sensing_raw_to_temp_c100(0x6666, 1700));

    TEST_ASSERT_EQUAL_INT32(0, siot_sensing_raw_to_rh_c100(0));
    TEST_ASSERT_EQUAL_INT32(5000, siot_sensing_raw_to_rh_c100(0x8000));
    TEST_ASSERT_EQUAL_INT32(10000, siot_sensing_raw_to_rh_c100(0xFFFF));
}
