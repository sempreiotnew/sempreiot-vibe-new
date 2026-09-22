#include "siot_ui_led.h"

#include <stddef.h>

#include "esp_log.h"
#include "esp_timer.h"

#include "siot_board_def.h"
#include "siot_evbus.h"
#include "siot_hal_pwm.h"

static const char *TAG = "siot_ui_led";

/* ---- Pattern engine (non-blocking, 50 ms esp_timer tick) — from siot_led.c
 * WHITE_BLINK / BLUE_BLINK run at 1 Hz (500 ms on / 500 ms off);
 * GREEN_BLINK / RED_BLINK are a 250 ms flash every 5 s. */
#define LED_TICK_MS            50
#define BLINK_HALF_TICKS       10   /* 500 ms on / 500 ms off */
#define SLOW_PERIOD_TICKS     100   /* 5 s */
#define SLOW_ON_TICKS           5   /* 250 ms flash */

static volatile siot_led_pattern_t s_pattern = SIOT_LED_OFF;
static volatile siot_led_pattern_t s_base = SIOT_LED_OFF;
static volatile uint32_t s_ticks_remaining;   /* 0 = steady (base) pattern */
static volatile uint32_t s_blink_phase;

static bool     s_is_board;
static uint8_t  s_state = SIOT_STATE_SETUP;
static uint8_t  s_level;
static bool     s_alarm;

static void led_set_rgb(bool r, bool g, bool b)
{
    siot_hal_pwm_set(0, r ? SIOT_HAL_PWM_DUTY_MAX : 0);
    siot_hal_pwm_set(1, g ? SIOT_HAL_PWM_DUTY_MAX : 0);
    siot_hal_pwm_set(2, b ? SIOT_HAL_PWM_DUTY_MAX : 0);
}

static void pattern_to_rgb(siot_led_pattern_t p, uint32_t phase, bool *r, bool *g, bool *b)
{
    const bool on = ((phase / BLINK_HALF_TICKS) & 1) == 0;
    const bool slow_on = (phase % SLOW_PERIOD_TICKS) < SLOW_ON_TICKS;
    *r = *g = *b = false;
    switch (p) {
    case SIOT_LED_WHITE_BLINK:     *r = on; *g = on; *b = on; break;
    case SIOT_LED_WHITE_SOLID:     *r = true; *g = true; *b = true; break;
    case SIOT_LED_GREEN_BLINK:     *g = slow_on; break;
    case SIOT_LED_GREEN_SOLID:     *g = true; break;
    case SIOT_LED_MAGENTA_SOLID:   *r = true; *b = true; break;
    case SIOT_LED_RED_SOLID:       *r = true; break;
    case SIOT_LED_RED_BLINK:       *r = slow_on; break;
    case SIOT_LED_BLUE_BLINK:      *b = on; break;
    case SIOT_LED_BLUE_SOLID:      *b = true; break;
    case SIOT_LED_OFF:
    default: break;
    }
}

static void led_tick(void *arg)
{
    (void)arg;
    static uint8_t last = 0xFF;

    siot_led_pattern_t p = s_pattern;
    if (s_ticks_remaining > 0) {
        s_ticks_remaining--;
        if (s_ticks_remaining == 0) {
            s_pattern = s_base;
            p = s_base;
            /* Resume the base pattern in its "off" part so a blue pulse is
             * not immediately followed by a green/white flash. */
            s_blink_phase = BLINK_HALF_TICKS;
        }
    }

    bool r, g, b;
    pattern_to_rgb(p, s_blink_phase, &r, &g, &b);
    s_blink_phase++;

    const uint8_t rgb = (uint8_t)((r << 2) | (g << 1) | b);
    if (rgb != last) {
        last = rgb;
        led_set_rgb(r, g, b);
    }
}

void siot_ui_led_set(siot_led_pattern_t pattern, uint32_t duration_ms)
{
    s_blink_phase = 0; /* always start a new pattern in its "on" half */
    s_ticks_remaining = duration_ms ? (duration_ms + LED_TICK_MS - 1) / LED_TICK_MS : 0;
    if (duration_ms == 0) s_base = pattern;
    s_pattern = pattern;
}

siot_led_pattern_t siot_ui_led_get_base(void)
{
    return s_base;
}

void siot_ui_led_comm_blink(void)
{
    if (s_pattern == SIOT_LED_BLUE_SOLID && s_ticks_remaining > 0) return;
    if (s_pattern == SIOT_LED_BLUE_BLINK && s_ticks_remaining > 0) return; /* IDENTIFY running */
    siot_ui_led_set(SIOT_LED_BLUE_SOLID, SIOT_LED_COMM_BLINK_MS);
}

/* ---- state → base pattern (brief §9 table) --------------------------- */

static siot_led_pattern_t pattern_for_state(void)
{
    if (s_alarm) return SIOT_LED_RED_SOLID;
    switch (s_state) {
    case SIOT_STATE_UNPROVISIONED_FACTORY: return SIOT_LED_RED_BLINK;
    case SIOT_STATE_SETUP:                 return SIOT_LED_WHITE_BLINK;
    case SIOT_STATE_JOINING:
    case SIOT_STATE_OFFLINE:               return SIOT_LED_WHITE_SOLID;
    case SIOT_STATE_ONLINE:
    case SIOT_STATE_DEGRADED:
        if (s_is_board) return SIOT_LED_MAGENTA_SOLID;
        return s_level == 1 ? SIOT_LED_GREEN_BLINK : SIOT_LED_OFF;
    case SIOT_STATE_FACTORY_RESET:
    default:                               return SIOT_LED_OFF;
    }
}

static void apply_state(void)
{
    const siot_led_pattern_t p = pattern_for_state();
    if (p != s_base) siot_ui_led_set(p, 0);
}

static void on_event(siot_evt_id_t id, const void *data, void *ctx)
{
    (void)ctx;
    switch (id) {
    case SIOT_EVT_STATE_CHANGED:
        s_state = ((const siot_evt_state_t *)data)->next;
        apply_state();
        break;
    case SIOT_EVT_MESH_LEVEL:
        s_level = ((const siot_evt_level_t *)data)->level;
        apply_state();
        break;
    case SIOT_EVT_ALARM_SET:
        s_alarm = true;
        apply_state();
        break;
    case SIOT_EVT_ALARM_CLEARED:
        s_alarm = false;
        apply_state();
        break;
    case SIOT_EVT_IDENTIFY: {
        uint32_t s = ((const siot_evt_identify_t *)data)->seconds;
        if (s == 0) s = SIOT_LED_IDENTIFY_DEFAULT_S;
        siot_ui_led_set(SIOT_LED_BLUE_BLINK, s * 1000);
        break;
    }
    case SIOT_EVT_SAFR_TX:
    case SIOT_EVT_SAFR_RX:
        siot_ui_led_comm_blink();
        break;
    default:
        break;
    }
}

esp_err_t siot_ui_led_init(bool is_board)
{
    s_is_board = is_board;
    const siot_board_def_t *bd = siot_board_def();
    const int pins[3] = {bd->led_r, bd->led_g, bd->led_b};
    esp_err_t err = siot_hal_pwm_init(pins, 3, bd->led_active_low);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "pwm init: %s", esp_err_to_name(err));
        return err;
    }
    led_set_rgb(false, false, false);

    const esp_timer_create_args_t args = {
        .callback = led_tick,
        .name     = "siot_led_tick",
    };
    esp_timer_handle_t t;
    err = esp_timer_create(&args, &t);
    if (err == ESP_OK) err = esp_timer_start_periodic(t, LED_TICK_MS * 1000);
    if (err != ESP_OK) return err;

    return siot_evbus_subscribe(SIOT_EVT_ANY, on_event, NULL, NULL);
}
