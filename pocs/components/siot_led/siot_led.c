#include "siot_led.h"

#include <stdbool.h>
#include <stddef.h>

#include "driver/ledc.h"
#include "esp_timer.h"

/* ---- Pin map (RGB LED, PWM) -- ported from pocs/patinha/main/patinha.c --
 * Same target/board convention as patinha (esp32s3); revisit if the real
 * PCB wiring differs once POC-BRIEF.md §0 hardware facts are filled in. */
#define LED_R_GPIO      14
#define LED_G_GPIO      47
#define LED_B_GPIO      48
#define LED_ACTIVE_LOW  0               /* 1 if common-anode (driven low)   */
#define LED_MODE        LEDC_LOW_SPEED_MODE
#define LED_TIMER       LEDC_TIMER_0
#define LED_RES         LEDC_TIMER_8_BIT
#define LED_FREQ_HZ     5000
#define LED_ON_DUTY     255

typedef struct { ledc_channel_t ch; int gpio; } led_t;
static const led_t leds[] = {
    { LEDC_CHANNEL_0, LED_R_GPIO },
    { LEDC_CHANNEL_1, LED_G_GPIO },
    { LEDC_CHANNEL_2, LED_B_GPIO },
};
#define LED_COUNT (sizeof(leds) / sizeof(leds[0]))

static void led_set_rgb(bool r, bool g, bool b)
{
    const bool on[LED_COUNT] = { r, g, b };
    for (size_t i = 0; i < LED_COUNT; i++) {
        uint32_t duty = on[i] ? LED_ON_DUTY : 0;
        if (LED_ACTIVE_LOW) duty = LED_ON_DUTY - duty;
        ESP_ERROR_CHECK(ledc_set_duty(LED_MODE, leds[i].ch, duty));
        ESP_ERROR_CHECK(ledc_update_duty(LED_MODE, leds[i].ch));
    }
}

static void led_hw_init(void)
{
    ledc_timer_config_t timer = {
        .speed_mode      = LED_MODE,
        .timer_num       = LED_TIMER,
        .duty_resolution = LED_RES,
        .freq_hz         = LED_FREQ_HZ,
        .clk_cfg         = LEDC_AUTO_CLK,
    };
    ESP_ERROR_CHECK(ledc_timer_config(&timer));
    for (size_t i = 0; i < LED_COUNT; i++) {
        ledc_channel_config_t ch = {
            .gpio_num   = leds[i].gpio,
            .speed_mode = LED_MODE,
            .channel    = leds[i].ch,
            .timer_sel  = LED_TIMER,
            .duty       = 0,
            .hpoint     = 0,
        };
        ESP_ERROR_CHECK(ledc_channel_config(&ch));
    }
    led_set_rgb(false, false, false);
}

/* ---- Pattern engine (non-blocking, 50 ms esp_timer tick) ----------------
 * WHITE_BLINK / BLUE_BLINK run at 1 Hz (500 ms on / 500 ms off);
 * GREEN_BLINK (root) is a short flash every 5 s. */
#define LED_TICK_MS            50
#define BLINK_HALF_TICKS       10   /* 500 ms on / 500 ms off */
#define SLOW_PERIOD_TICKS     100   /* 5 s */
#define SLOW_ON_TICKS           5   /* 250 ms flash */

static volatile siot_led_pattern_t s_pattern = SIOT_LED_OFF;
static volatile siot_led_pattern_t s_base = SIOT_LED_OFF; /* what a timed pattern reverts to */
static volatile uint32_t s_ticks_remaining;   /* 0 = steady (base) pattern */
static volatile uint32_t s_blink_phase;

static void pattern_to_rgb(siot_led_pattern_t p, uint32_t phase,
                           bool *r, bool *g, bool *b)
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

void siot_led_init(void)
{
    led_hw_init();

    const esp_timer_create_args_t args = {
        .callback = led_tick,
        .name     = "siot_led_tick",
    };
    esp_timer_handle_t t;
    ESP_ERROR_CHECK(esp_timer_create(&args, &t));
    ESP_ERROR_CHECK(esp_timer_start_periodic(t, LED_TICK_MS * 1000));
}

void siot_led_set_pattern(siot_led_pattern_t pattern, uint32_t duration_ms)
{
    s_blink_phase = 0; /* always start a new pattern in its "on" half */
    s_ticks_remaining = duration_ms
        ? (duration_ms + LED_TICK_MS - 1) / LED_TICK_MS
        : 0;
    if (duration_ms == 0) s_base = pattern; /* steady state: remembered */
    s_pattern = pattern;
}

siot_led_pattern_t siot_led_get_base(void)
{
    return s_base;
}

void siot_led_comm_blink(void)
{
    /* One pulse per frame; a frame landing while the pulse is still lit is
     * folded into it (no restart), so a burst reads as separate blinks and
     * never as solid blue. */
    if (s_pattern == SIOT_LED_BLUE_SOLID && s_ticks_remaining > 0) return;
    /* Don't cut a running IDENTIFY (timed slow blue blink) short. */
    if (s_pattern == SIOT_LED_BLUE_BLINK && s_ticks_remaining > 0) return;
    siot_led_set_pattern(SIOT_LED_BLUE_SOLID, SIOT_LED_COMM_BLINK_MS);
}
